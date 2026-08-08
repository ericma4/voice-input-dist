"""为 CapsWriter 音素纠错器提供轻量的文件加载与热更新封装。"""

from __future__ import annotations

import threading
from pathlib import Path

from .caps.hotword.hot_phoneme import PhonemeCorrector
from .paths import HOTWORDS_PATH, ensure_directories


class HotwordProcessor:
    """沿用 CapsWriter 的 0.85 替换阈值，并在每次识别前检查文件时间。"""

    def __init__(self, path: Path = HOTWORDS_PATH) -> None:
        self.path = path
        self._lock = threading.RLock()
        self._mtime_ns = -1
        self._corrector = PhonemeCorrector(threshold=0.85, similar_threshold=0.60)
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        with self._lock:
            ensure_directories()
            if not self.path.exists():
                self.path.write_text(
                    "# Format: final text | spoken alias 1 | spoken alias 2\n",
                    encoding="utf-8",
                )
            mtime_ns = self.path.stat().st_mtime_ns
            if not force and mtime_ns == self._mtime_ns:
                return
            self._corrector.update_hotwords(self.path.read_text(encoding="utf-8"))
            self._mtime_ns = mtime_ns

    def correct(self, text: str) -> str:
        with self._lock:
            self.reload()
            return self._corrector.correct(text).text
