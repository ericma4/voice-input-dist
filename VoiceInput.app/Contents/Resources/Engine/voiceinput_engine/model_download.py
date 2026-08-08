"""下载 VoiceInput 支持的 Qwen3-ASR MLX 模型，并输出 JSON 进度行。"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from pathlib import Path

from .paths import MODEL_VARIANTS, ensure_directories, model_is_complete, model_path


def _emit(**payload) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _directory_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for item in path.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            pass
    return total


def download(variant: str, use_mirror: bool) -> int:
    if variant not in MODEL_VARIANTS:
        raise ValueError(f"Unsupported model variant: {variant}")
    ensure_directories()
    if model_is_complete(variant):
        _emit(event="complete", variant=variant, progress=1.0)
        return 0

    endpoint = "https://hf-mirror.com" if use_mirror else "https://huggingface.co"
    if use_mirror:
        # huggingface_hub 在导入时读取该变量，因此必须先设置再延迟导入。
        os.environ["HF_ENDPOINT"] = endpoint
    from huggingface_hub import HfApi, snapshot_download

    repo_id = MODEL_VARIANTS[variant]["repo"]
    target = model_path(variant)
    target.mkdir(parents=True, exist_ok=True)
    info = HfApi(endpoint=endpoint).model_info(repo_id, files_metadata=True)
    total_bytes = sum(int(getattr(item, "size", 0) or 0) for item in info.siblings)
    result: dict[str, object] = {"error": None}

    def worker() -> None:
        try:
            snapshot_download(repo_id=repo_id, local_dir=target)
        except Exception as exc:
            result["error"] = f"{type(exc).__name__}: {exc}"

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    _emit(event="started", variant=variant, total_bytes=total_bytes)
    while thread.is_alive():
        downloaded = _directory_bytes(target)
        progress = min(0.99, downloaded / total_bytes) if total_bytes else 0.0
        _emit(
            event="progress",
            variant=variant,
            downloaded_bytes=downloaded,
            total_bytes=total_bytes,
            progress=progress,
        )
        thread.join(timeout=0.5)

    if result["error"] is not None:
        _emit(event="error", variant=variant, message=result["error"])
        return 1
    if not model_is_complete(variant):
        _emit(event="error", variant=variant, message="Downloaded model is incomplete")
        return 1
    _emit(event="complete", variant=variant, progress=1.0)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Install a VoiceInput Qwen3-ASR model")
    parser.add_argument("variant", choices=sorted(MODEL_VARIANTS))
    parser.add_argument("--mirror", action="store_true")
    args = parser.parse_args(argv)
    return download(args.variant, args.mirror)


if __name__ == "__main__":
    raise SystemExit(main())
