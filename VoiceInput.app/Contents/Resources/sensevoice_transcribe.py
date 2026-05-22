#!/usr/bin/env python3
"""Small CLI wrapper for SenseVoice transcription."""

from __future__ import annotations

import argparse
import contextlib
import errno
import os
import sys

DEFAULT_MODEL = "iic/SenseVoiceSmall"
DEFAULT_VAD_MODEL = "fsmn-vad"
LOCAL_MODEL = "~/.cache/modelscope/hub/models/iic/SenseVoiceSmall"
LOCAL_VAD_MODEL = "~/.cache/modelscope/hub/models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"


def prepare_subprocess_path() -> None:
    existing = os.environ.get("PATH", "")
    candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    parts = [path for path in existing.split(os.pathsep) if path]
    for candidate in reversed(candidates):
        if os.path.isdir(candidate) and candidate not in parts:
            parts.insert(0, candidate)
    os.environ["PATH"] = os.pathsep.join(parts)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Transcribe audio with SenseVoice Small.")
    parser.add_argument("audio", nargs="?", help="Path to an audio file.")
    parser.add_argument(
        "--model",
        default=os.environ.get("SENSEVOICE_MODEL", DEFAULT_MODEL),
        help="FunASR/modelscope model id or local model path.",
    )
    parser.add_argument(
        "--language",
        default=os.environ.get("SENSEVOICE_LANGUAGE", "auto"),
        choices=["auto", "zh", "en", "yue", "ja", "ko", "nospeech"],
        help="Recognition language. Use auto for Chinese/English mixed input.",
    )
    parser.add_argument(
        "--device",
        default=os.environ.get("SENSEVOICE_DEVICE", "cpu"),
        help="Inference device, for example cpu or cuda:0.",
    )
    parser.add_argument(
        "--warmup",
        action="store_true",
        help="Load the model once so dependencies and model files are cached.",
    )
    return parser.parse_args()


def apply_compatibility_shims() -> None:
    # ModelScope currently references this Linux errno on Python 3.14/macOS.
    if not hasattr(errno, "EREMOTEIO"):
        errno.EREMOTEIO = 121


def local_model_or_id(model: str, default_ids: set[str], local_path: str) -> str:
    expanded = os.path.expanduser(local_path)
    if model in default_ids and os.path.isdir(expanded):
        return expanded
    return os.path.expanduser(model)


def fail(message: str, code: int = 1) -> int:
    print(message, file=sys.stderr)
    return code


def main() -> int:
    apply_compatibility_shims()
    prepare_subprocess_path()

    args = parse_args()
    model_path = local_model_or_id(args.model, {DEFAULT_MODEL}, LOCAL_MODEL)
    vad_model_path = local_model_or_id(
        os.environ.get("SENSEVOICE_VAD_MODEL", DEFAULT_VAD_MODEL),
        {DEFAULT_VAD_MODEL, "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"},
        LOCAL_VAD_MODEL,
    )

    if not args.warmup and not args.audio:
        return fail("Missing audio file path.")

    if args.audio and not os.path.exists(args.audio):
        return fail(f"Audio file does not exist: {args.audio}")

    try:
        with contextlib.redirect_stdout(sys.stderr):
            from funasr import AutoModel
            from funasr.utils.postprocess_utils import rich_transcription_postprocess
    except ImportError as exc:
        return fail(
            "SenseVoice dependencies are not installed. "
            "Run Scripts/setup_sensevoice.sh from the project directory. "
            f"Missing import: {exc}",
            2,
        )

    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = AutoModel(
                model=model_path,
                trust_remote_code=True,
                vad_model=vad_model_path,
                vad_kwargs={"max_single_segment_time": 30000},
                device=args.device,
                disable_update=True,
        )

        if args.warmup:
            print("SenseVoice ready.")
            return 0

        with contextlib.redirect_stdout(sys.stderr):
            result = model.generate(
                input=args.audio,
                cache={},
                language=args.language,
                use_itn=True,
                batch_size_s=60,
                merge_vad=True,
                merge_length_s=15,
            )
    except Exception as exc:  # noqa: BLE001 - surface model/runtime failures to Swift.
        return fail(f"SenseVoice transcription failed: {exc}")

    if not result:
        return 0

    text_parts = []
    for item in result:
        text = item.get("text", "") if isinstance(item, dict) else str(item)
        text = rich_transcription_postprocess(text).strip()
        if text:
            text_parts.append(text)

    print(" ".join(text_parts).strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
