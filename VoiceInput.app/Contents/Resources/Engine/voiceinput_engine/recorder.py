"""按需打开麦克风，并复用 CapsWriter 的 48 kHz→16 kHz 取样策略。"""

from __future__ import annotations

import threading
from collections.abc import Callable

import numpy as np
import sounddevice as sd


class AudioRecorder:
    """一次长按对应一次内存录音；从不把原始音频写入磁盘。"""

    SAMPLE_RATE = 48000
    BLOCK_DURATION = 0.05

    def __init__(self, on_level: Callable[[float], None]) -> None:
        self._on_level = on_level
        self._lock = threading.RLock()
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._active = False

    @property
    def active(self) -> bool:
        with self._lock:
            return self._active

    def start(self) -> None:
        with self._lock:
            if self._active:
                return
            self._reload_portaudio()
            device = sd.query_devices(kind="input")
            channels = max(1, min(2, int(device["max_input_channels"])))
            self._chunks = []
            self._stream = sd.InputStream(
                samplerate=self.SAMPLE_RATE,
                blocksize=int(self.SAMPLE_RATE * self.BLOCK_DURATION),
                dtype="float32",
                channels=channels,
                callback=self._audio_callback,
            )
            self._active = True
            try:
                self._stream.start()
            except Exception:
                self._active = False
                self._stream = None
                raise

    def stop(self) -> np.ndarray:
        """关闭输入流并返回 16 kHz 单声道数据；关闭超时不会卡住全局按键线程。"""
        with self._lock:
            self._active = False
            stream = self._stream
            self._stream = None
            chunks = self._chunks
            self._chunks = []

        if stream is not None:
            closer = threading.Thread(target=self._close_stream, args=(stream,), daemon=True)
            closer.start()
            closer.join(timeout=5.0)

        self._on_level(0.0)
        if not chunks:
            return np.asarray([], dtype=np.float32)
        return np.concatenate(chunks).astype(np.float32, copy=False)

    def abort(self) -> None:
        """停止并丢弃本轮数据，用于应用退出或录音故障。"""
        self.stop()

    def _audio_callback(self, indata, frames, time_info, status) -> None:
        del frames, time_info, status
        with self._lock:
            if not self._active:
                return
            frame = np.asarray(indata, dtype=np.float32)
            mono_16k = np.mean(frame[::3], axis=1, dtype=np.float32)
            self._chunks.append(mono_16k.copy())
        rms = float(np.sqrt(np.mean(np.square(frame), dtype=np.float64)))
        self._on_level(max(0.0, min(1.0, rms * 12.0)))

    @staticmethod
    def _close_stream(stream: sd.InputStream) -> None:
        try:
            stream.stop()
            stream.close()
        except Exception:
            pass

    @staticmethod
    def _reload_portaudio() -> None:
        """刷新 macOS 默认输入设备，沿用 CapsWriter 对热插拔麦克风的处理。"""
        try:
            sd._terminate()
            sd._ffi.dlclose(sd._lib)
            sd._lib = sd._ffi.dlopen(sd._libname)
            sd._initialize()
        except Exception:
            # 私有 API 在 sounddevice 版本变化时可能不可用；失败后仍可正常尝试建流。
            pass
