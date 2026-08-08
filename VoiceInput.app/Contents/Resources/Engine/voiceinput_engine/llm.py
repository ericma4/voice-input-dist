"""可选的 OpenAI-compatible 转录纠错；API Key 只从 macOS Keychain 读取。"""

from __future__ import annotations

import json
import subprocess
import urllib.request

from .config import EngineConfig


KEYCHAIN_SERVICE = "com.yetone.VoiceInput"
KEYCHAIN_ACCOUNT = "default"


def read_api_key() -> str:
    """通过系统 security 工具读取本应用条目，不把密钥放进配置或日志。"""
    result = subprocess.run(
        [
            "/usr/bin/security",
            "find-generic-password",
            "-w",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def refine(text: str, config: EngineConfig) -> str:
    """调用兼容接口；任何网络或解析失败由上层决定是否回退原文本。"""
    api_key = read_api_key()
    if not api_key:
        raise RuntimeError("LLM API key is not configured")
    url = f"{config.llm_api_base_url}/chat/completions"
    payload = {
        "model": config.llm_model,
        "messages": [
            {"role": "system", "content": config.llm_prompt},
            {"role": "user", "content": text},
        ],
        "temperature": 0.3,
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        body = json.load(response)
    value = body["choices"][0]["message"]["content"].strip()
    return value or text
