"""不触碰麦克风、键盘和 Metal 的 Python 内核定向测试。"""

from __future__ import annotations

import importlib.util
import threading
import unittest
from unittest.mock import Mock, patch

import numpy as np

from voiceinput_engine.caps.shortcut.macos_caps_remap import (
    CAPS_LOCK_HID,
    F18_HID,
    build_caps_to_f18_mapping,
    parse_user_key_mapping_raw,
)
from voiceinput_engine.postprocess import remove_fillers
from voiceinput_engine.recorder import AudioRecorder, AudioStreamCloseTimeout


class PostprocessTests(unittest.TestCase):
    def test_removes_confirmed_chinese_and_english_fillers(self) -> None:
        self.assertEqual(remove_fillers("嗯，我想 uh 测试一下"), "我想测试一下")
        self.assertEqual(remove_fillers("um hello erm world"), "hello world")

    def test_preserves_semantic_english_words(self) -> None:
        self.assertEqual(
            remove_fillers("The term like is meaningful"),
            "The term like is meaningful",
        )


class CapsRemapTests(unittest.TestCase):
    def test_replaces_only_existing_caps_mapping(self) -> None:
        existing = [
            {
                "HIDKeyboardModifierMappingSrc": 123,
                "HIDKeyboardModifierMappingDst": 456,
            },
            {
                "HIDKeyboardModifierMappingSrc": CAPS_LOCK_HID,
                "HIDKeyboardModifierMappingDst": 999,
            },
        ]
        result = build_caps_to_f18_mapping(existing)
        self.assertIn(existing[0], result)
        self.assertIn(
            {
                "HIDKeyboardModifierMappingSrc": CAPS_LOCK_HID,
                "HIDKeyboardModifierMappingDst": F18_HID,
            },
            result,
        )
        self.assertEqual(len(result), 2)

    def test_parses_empty_hidutil_output(self) -> None:
        self.assertEqual(parse_user_key_mapping_raw("()"), [])
        self.assertEqual(parse_user_key_mapping_raw("(null)"), [])


class RecorderShutdownTests(unittest.TestCase):
    def test_close_timeout_is_reported_instead_of_silently_leaking_microphone(self) -> None:
        release_close = threading.Event()

        class BlockingStream:
            """模拟卡在 PortAudio/CoreAudio 原生 stop 调用中的输入流。"""

            def stop(self) -> None:
                release_close.wait()

            def close(self) -> None:
                pass

        recorder = AudioRecorder(lambda level: None)
        recorder._stream = BlockingStream()
        recorder._active = True
        recorder._chunks = [np.ones(1600, dtype=np.float32)]

        try:
            with patch.object(AudioRecorder, "CLOSE_TIMEOUT_SECONDS", 0.01):
                with self.assertRaises(AudioStreamCloseTimeout):
                    recorder.stop()
        finally:
            # 让测试用的 daemon 线程收尾，避免把人为阻塞带到其他测试。
            release_close.set()

    def test_engine_process_uses_immediate_exit_after_explicit_cleanup(self) -> None:
        from voiceinput_engine import service

        exit_codes: list[int] = []
        with patch.object(service, "main", return_value=7):
            service.run_process(exit_process=exit_codes.append)
        self.assertEqual(exit_codes, [7])

    def test_close_timeout_requests_engine_shutdown(self) -> None:
        from voiceinput_engine.service import VoiceInputEngine

        class TimeoutRecorder:
            """模拟已开始录音、但 PortAudio 无法结束输入流的状态。"""

            active = True

            def stop(self) -> np.ndarray:
                raise AudioStreamCloseTimeout("simulated timeout")

        engine = VoiceInputEngine()
        engine.recorder = TimeoutRecorder()
        engine.state = Mock()

        engine._stop_recording()

        self.assertTrue(engine.stop_event.is_set())
        engine.state.update.assert_called_once_with(
            state="error",
            message="Microphone did not close. Restart VoiceInput.",
            audio_level=0.0,
        )


@unittest.skipUnless(
    importlib.util.find_spec("pypinyin") and importlib.util.find_spec("rapidfuzz"),
    "CapsWriter hotword dependencies are not installed",
)
class HotwordTests(unittest.TestCase):
    def test_alias_format_uses_capswriter_phoneme_corrector(self) -> None:
        from voiceinput_engine.caps.hotword.hot_phoneme import PhonemeCorrector

        corrector = PhonemeCorrector(threshold=0.85, similar_threshold=0.60)
        corrector.update_hotwords("CapsWriter | caps writer\n")
        self.assertEqual(corrector.correct("打开 caps writer").text, "打开 CapsWriter")


if __name__ == "__main__":
    unittest.main()
