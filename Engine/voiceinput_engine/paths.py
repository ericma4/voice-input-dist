"""集中定义 VoiceInput 引擎使用的 macOS 标准目录。"""

from __future__ import annotations

import os
from pathlib import Path


# 测试可以通过 VOICEINPUT_HOME 使用临时目录；正常运行严格使用
# ~/Library/Application Support/VoiceInput，避免模型和运行数据污染 Git 仓库。
_HOME_OVERRIDE = os.environ.get("VOICEINPUT_HOME")
APP_SUPPORT = Path(
    _HOME_OVERRIDE
    or Path.home() / "Library" / "Application Support" / "VoiceInput"
).expanduser()
MODEL_DIR = APP_SUPPORT / "Models"
RUNTIME_DIR = APP_SUPPORT / "Runtime"
STATE_DIR = APP_SUPPORT / "State"
CONFIG_PATH = APP_SUPPORT / "config.json"
HOTWORDS_PATH = APP_SUPPORT / "hotwords.txt"
STATE_PATH = STATE_DIR / "engine.json"
PID_PATH = STATE_DIR / "engine.pid"
REMAP_STATE_PATH = STATE_DIR / "original_user_key_mapping.json"
# 测试覆盖整个数据根目录时，日志也留在临时目录；正式运行仍遵循 macOS Logs 约定。
LOG_DIR = (
    APP_SUPPORT / "Logs"
    if _HOME_OVERRIDE
    else Path.home() / "Library" / "Logs" / "VoiceInput"
)
ENGINE_LOG_PATH = LOG_DIR / "engine.log"

MODEL_VARIANTS = {
    "8bit": {
        "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "directory": "Qwen3-ASR-1.7B-8bit",
    },
    "4bit": {
        "repo": "mlx-community/Qwen3-ASR-1.7B-4bit",
        "directory": "Qwen3-ASR-1.7B-4bit",
    },
}


def ensure_directories() -> None:
    """创建运行所需目录；不创建或下载任何模型文件。"""
    for path in (APP_SUPPORT, MODEL_DIR, RUNTIME_DIR, STATE_DIR, LOG_DIR):
        path.mkdir(parents=True, exist_ok=True)


def model_path(variant: str) -> Path:
    """返回指定模型规格的标准安装目录。"""
    item = MODEL_VARIANTS.get(variant, MODEL_VARIANTS["8bit"])
    return MODEL_DIR / item["directory"]


def model_is_complete(variant: str) -> bool:
    """用关键文件判断模型是否足以交给 mlx-qwen3-asr 加载。"""
    path = model_path(variant)
    return (
        (path / "config.json").is_file()
        and any(path.glob("*.safetensors"))
        and (path / "tokenizer_config.json").is_file()
    )
