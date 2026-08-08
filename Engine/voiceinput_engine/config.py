"""VoiceInput Swift 前端与 Python 引擎共享的 JSON 配置。"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from dataclasses import asdict, dataclass, fields
from pathlib import Path

from .paths import CONFIG_PATH, ensure_directories


DEFAULT_LLM_PROMPT = """You are a conservative speech recognition error corrector.
ONLY fix clear, obvious transcription mistakes. Do not rephrase, answer, translate,
or add information. Return only the corrected text. If the input is already correct,
return it exactly as-is."""

SUPPORTED_LANGUAGES = {
    "auto": None,
    "chinese": "Chinese",
    "english": "English",
    "spanish": "Spanish",
    "italian": "Italian",
    "french": "French",
}


@dataclass(slots=True)
class EngineConfig:
    """只包含当前产品界面真正暴露的设置，避免继承旧项目的无关开关。"""

    language: str = "auto"
    model_variant: str = "8bit"
    auto_paste: bool = True
    remove_fillers: bool = True
    llm_enabled: bool = False
    llm_api_base_url: str = "https://api.openai.com/v1"
    llm_model: str = "gpt-4o-mini"
    llm_prompt: str = DEFAULT_LLM_PROMPT
    use_hf_mirror: bool = False

    def normalized(self) -> "EngineConfig":
        """收紧来自手工编辑 JSON 的值，防止无效选项进入模型调用。"""
        if self.language not in SUPPORTED_LANGUAGES:
            self.language = "auto"
        if self.model_variant not in {"8bit", "4bit"}:
            self.model_variant = "8bit"
        self.llm_api_base_url = self.llm_api_base_url.strip().rstrip("/")
        self.llm_model = self.llm_model.strip()
        return self


class ConfigStore:
    """线程安全地加载配置，并在文件变化时即时刷新非模型设置。"""

    def __init__(self, path: Path = CONFIG_PATH) -> None:
        self.path = path
        self._lock = threading.RLock()
        self._mtime_ns = -1
        self._config = EngineConfig()

    def load(self, force: bool = False) -> EngineConfig:
        with self._lock:
            ensure_directories()
            if not self.path.exists():
                self.save(self._config)
                return self._config

            mtime_ns = self.path.stat().st_mtime_ns
            if not force and mtime_ns == self._mtime_ns:
                return self._config

            raw = json.loads(self.path.read_text(encoding="utf-8"))
            allowed = {field.name for field in fields(EngineConfig)}
            values = {key: value for key, value in raw.items() if key in allowed}
            self._config = EngineConfig(**values).normalized()
            self._mtime_ns = mtime_ns
            return self._config

    def save(self, config: EngineConfig) -> None:
        """原子写入配置，保证 Swift 保存期间引擎不会读到半截 JSON。"""
        with self._lock:
            ensure_directories()
            config.normalized()
            fd, temp_name = tempfile.mkstemp(
                dir=self.path.parent,
                prefix=".config-",
                suffix=".json",
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    json.dump(asdict(config), handle, ensure_ascii=False, indent=2)
                    handle.write("\n")
                os.replace(temp_name, self.path)
            except Exception:
                try:
                    os.unlink(temp_name)
                except OSError:
                    pass
                raise
            self._config = config
            self._mtime_ns = self.path.stat().st_mtime_ns
