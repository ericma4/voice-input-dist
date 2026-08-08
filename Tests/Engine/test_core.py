"""不触碰麦克风、键盘和 Metal 的 Python 内核定向测试。"""

from __future__ import annotations

import importlib.util
import unittest

from voiceinput_engine.caps.shortcut.macos_caps_remap import (
    CAPS_LOCK_HID,
    F18_HID,
    build_caps_to_f18_mapping,
    parse_user_key_mapping_raw,
)
from voiceinput_engine.postprocess import remove_fillers


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
