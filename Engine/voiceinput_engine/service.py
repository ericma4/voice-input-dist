"""VoiceInput 的单进程 Python 内核：Caps Lock、录音、ASR、纠错与上屏。"""

from __future__ import annotations

import logging
import logging.handlers
import os
import queue
import signal
import threading
import time
from pathlib import Path

import numpy as np

from .asr import ModelMissingError, QwenASREngine
from .caps.shortcut.macos_caps_controller import MacOSCapsController
from .caps.shortcut.macos_caps_remap import MacOSCapsRemapSession
from .caps.shortcut.macos_caps_state import toggle_caps_lock_state
from .caps.shortcut.macos_f18_listener import MacOSF18Listener
from .config import ConfigStore
from .hotwords import HotwordProcessor
from .llm import refine
from .output import copy_and_optionally_paste
from .paths import ENGINE_LOG_PATH, PID_PATH, ensure_directories
from .postprocess import remove_fillers
from .recorder import AudioRecorder
from .state import StatePublisher


logger = logging.getLogger("voiceinput.engine")


def _configure_logging() -> None:
    """日志只记录状态和异常类型；识别文本、音频和密钥永不写入。"""
    ensure_directories()
    logger.setLevel(logging.INFO)
    handler = logging.handlers.RotatingFileHandler(
        ENGINE_LOG_PATH,
        maxBytes=1_000_000,
        backupCount=3,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.handlers.clear()
    logger.addHandler(handler)


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class VoiceInputEngine:
    """把已确认的产品链路收敛在一个后台进程，避免旧 client/server 双重生命周期。"""

    def __init__(self) -> None:
        self.stop_event = threading.Event()
        self.state = StatePublisher()
        self.config_store = ConfigStore()
        self.hotwords: HotwordProcessor | None = None
        self.asr: QwenASREngine | None = None
        self.remap: MacOSCapsRemapSession | None = None
        self.listener: MacOSF18Listener | None = None
        self.keyboard_ready = False
        self.model_ready = False
        self._recognition_lock = threading.Lock()
        # MLX 的 GPU stream 属于创建它的线程。录音回调只负责投递音频，模型加载和
        # 实际转写都固定在 run() 所在的引擎主线程，避免跨线程调用导致 RuntimeError。
        self._recognition_queue: queue.Queue[np.ndarray] = queue.Queue(maxsize=1)
        self._recognition_pending = threading.Event()
        self.recorder = AudioRecorder(self._publish_audio_level)
        self.controller = MacOSCapsController(
            start_recording=self._start_recording,
            stop_recording=self._stop_recording,
            toggle_caps_lock=toggle_caps_lock_state,
            hold_threshold_ms=200,
        )

    def run(self) -> int:
        """启动键盘接管和模型；任一阶段失败都进入可诊断状态并安全恢复映射。"""
        _configure_logging()
        ensure_directories()
        self._claim_single_instance()
        self._install_signal_handlers()
        config = self.config_store.load(force=True)
        self.state.update(
            state="starting",
            message="Starting keyboard control…",
            model_variant=config.model_variant,
            language=config.language,
            last_text="",
        )

        try:
            self.state.update(state="loading_model", message="Loading Qwen3-ASR model…")
            self.hotwords = HotwordProcessor()
            self.asr = QwenASREngine(config.model_variant)
            self.model_ready = True
            # Metal 首次加载模型时可能耗时较长。若此时已经收到退出信号，必须在修改
            # Caps Lock 映射之前结束；否则前端退出后，迟到的模型加载结果会重新接管键盘。
            if self.stop_event.is_set():
                return 0
            # 模型加载期间不修改系统键盘映射；这样用户若在冷启动阶段退出，Caps Lock
            # 不会因为第三方 Metal 初始化尚未返回而滞留在 F18。模型就绪后再接管键盘。
            self.state.update(state="starting", message="Starting keyboard control…")
            self._start_keyboard()
            self._publish_resting_state()
            logger.info("engine ready model=%s", config.model_variant)

            while not self.stop_event.is_set():
                try:
                    samples = self._recognition_queue.get(timeout=0.25)
                except queue.Empty:
                    samples = None
                if samples is not None:
                    try:
                        self._recognize_and_output(samples)
                    finally:
                        self._recognition_pending.clear()
                self.config_store.load()
                if self.hotwords is not None:
                    self.hotwords.reload()
                if self.listener is not None and self.keyboard_ready:
                    self.listener.check_health()
            return 0
        except ModelMissingError as exc:
            logger.warning("model missing")
            self.state.update(state="model_missing", message=str(exc))
            while not self.stop_event.wait(1.0):
                pass
            return 2
        except Exception as exc:
            logger.exception("engine startup failed: %s", type(exc).__name__)
            self.state.update(state="error", message=f"Engine error: {type(exc).__name__}")
            while not self.stop_event.wait(1.0):
                pass
            return 1
        finally:
            self.shutdown()

    def shutdown(self) -> None:
        """先停止事件 tap，再恢复系统映射，保证退出后 Caps Lock 立即回到原状。"""
        logger.info("engine stopping")
        try:
            self.recorder.abort()
        except Exception:
            pass
        if self.listener is not None:
            try:
                self.listener.stop()
            except Exception:
                pass
        if self.remap is not None:
            try:
                self.remap.restore()
            except Exception:
                logger.exception("failed to restore Caps Lock mapping")
        if self.asr is not None:
            self.asr.close()
        self.state.update(
            state="stopped",
            message="Stopped",
            audio_level=0.0,
            last_text="",
        )
        try:
            if PID_PATH.exists() and PID_PATH.read_text().strip() == str(os.getpid()):
                PID_PATH.unlink()
        except Exception:
            pass

    def _claim_single_instance(self) -> None:
        """PID 文件只用于精确定位本引擎；不会扫描或终止旧 CapsWriter。"""
        if PID_PATH.exists():
            try:
                existing_pid = int(PID_PATH.read_text().strip())
                if existing_pid != os.getpid() and _pid_is_alive(existing_pid):
                    raise RuntimeError(f"VoiceInput engine is already running (pid={existing_pid})")
            except ValueError:
                pass
        PID_PATH.write_text(str(os.getpid()), encoding="utf-8")

    def _install_signal_handlers(self) -> None:
        def request_stop(signum, frame) -> None:
            del signum, frame
            self.stop_event.set()

        signal.signal(signal.SIGTERM, request_stop)
        signal.signal(signal.SIGINT, request_stop)

    def _start_keyboard(self) -> None:
        """先验证 F18 tap，再修改全局映射；缺权限时绝不把 Caps Lock 留在 F18 状态。"""
        self.listener = MacOSF18Listener(
            on_down=self.controller.on_f18_down,
            on_up=self.controller.on_f18_up,
            on_tap_failed=self._on_keyboard_failure,
        )
        self.listener.start()
        if self.listener._tap is None or not self.listener.tap_healthy():
            self.listener.stop()
            self.keyboard_ready = False
            self.state.update(
                state="permission_required",
                message="Enable Accessibility and Input Monitoring, then restart VoiceInput.",
            )
            return

        self.remap = MacOSCapsRemapSession()
        self.remap.start()
        self.keyboard_ready = True

    def _on_keyboard_failure(self) -> None:
        """运行中 tap 失效时立即放回 Caps Lock，并由前端显示权限错误。"""
        if not self.keyboard_ready:
            return
        self.keyboard_ready = False
        if self.remap is not None:
            try:
                self.remap.restore()
            except Exception:
                logger.exception("keyboard failure restore failed")
        self.state.update(
            state="permission_required",
            message="Keyboard permission was lost. Restart VoiceInput after restoring access.",
            audio_level=0.0,
        )

    def _publish_resting_state(self) -> None:
        config = self.config_store.load()
        if self.model_ready and self.keyboard_ready:
            self.state.update(
                state="ready",
                message="Ready",
                audio_level=0.0,
                model_variant=config.model_variant,
                language=config.language,
            )
        elif not self.keyboard_ready:
            self.state.update(
                state="permission_required",
                message="Enable Accessibility and Input Monitoring, then restart VoiceInput.",
            )

    def _publish_audio_level(self, level: float) -> None:
        if self.recorder.active:
            self.state.update(audio_level=round(level, 3))

    def _start_recording(self) -> None:
        if not (self.model_ready and self.keyboard_ready) or self.asr is None:
            return
        if self._recognition_pending.is_set() or self._recognition_lock.locked() or self.recorder.active:
            return
        try:
            self.recorder.start()
            self.state.update(state="recording", message="Listening…", audio_level=0.0)
        except Exception as exc:
            logger.exception("microphone start failed: %s", type(exc).__name__)
            self.state.update(state="error", message="Microphone is unavailable.")

    def _stop_recording(self) -> None:
        if not self.recorder.active:
            return
        samples = self.recorder.stop()
        if samples.size < 1600:
            self._publish_resting_state()
            return
        self.state.update(state="transcribing", message="Transcribing…", audio_level=0.0)
        self._recognition_pending.set()
        try:
            self._recognition_queue.put_nowait(samples)
        except queue.Full:
            # maxsize=1 且 pending 会阻止第二次录音；这里仅防御异常回调重入。
            self._recognition_pending.clear()
            logger.warning("recognition queue was unexpectedly full")
            self._publish_resting_state()

    def _recognize_and_output(self, samples: np.ndarray) -> None:
        with self._recognition_lock:
            try:
                config = self.config_store.load(force=True)
                if self.asr is None:
                    return
                text = self.asr.transcribe(samples, config.language)
                if not text:
                    self._publish_resting_state()
                    return
                if self.hotwords is not None:
                    text = self.hotwords.correct(text)
                if config.remove_fillers:
                    text = remove_fillers(text)
                llm_warning = ""
                if config.llm_enabled and text:
                    self.state.update(state="refining", message="Refining…")
                    try:
                        text = refine(text, config)
                    except Exception as exc:
                        llm_warning = " LLM refinement failed; original transcript was used."
                        logger.warning("LLM refinement failed: %s", type(exc).__name__)
                if text:
                    copy_and_optionally_paste(text, config.auto_paste)
                self.state.update(
                    state="ready",
                    message=f"Ready.{llm_warning}" if llm_warning else "Ready",
                    last_text=text,
                    audio_level=0.0,
                )
            except Exception as exc:
                logger.exception("recognition failed: %s", type(exc).__name__)
                self.state.update(
                    state="error",
                    message=f"Recognition failed: {type(exc).__name__}",
                    audio_level=0.0,
                )


def main() -> int:
    return VoiceInputEngine().run()


if __name__ == "__main__":
    raise SystemExit(main())
