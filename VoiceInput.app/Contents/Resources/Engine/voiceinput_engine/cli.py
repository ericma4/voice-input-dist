"""VoiceInput 的诊断备用 CLI；日常生命周期仍由 Swift 菜单管理。"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import signal
import subprocess
import sys
import time
from pathlib import Path

from .model_download import download
from .paths import ENGINE_LOG_PATH, PID_PATH, STATE_PATH, ensure_directories, model_is_complete


def _read_pid() -> int | None:
    try:
        return int(PID_PATH.read_text().strip())
    except Exception:
        return None


def _alive(pid: int | None) -> bool:
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def start() -> int:
    ensure_directories()
    pid = _read_pid()
    if _alive(pid):
        print(f"VoiceInput engine is already running (pid={pid})")
        return 0
    log_handle = ENGINE_LOG_PATH.open("a", encoding="utf-8")
    process = subprocess.Popen(
        [sys.executable, "-m", "voiceinput_engine.service"],
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )
    log_handle.close()
    deadline = time.time() + 60
    while time.time() < deadline:
        if process.poll() is not None:
            print("VoiceInput engine exited during startup", file=sys.stderr)
            return process.returncode or 1
        try:
            state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
            if state.get("pid") == process.pid and state.get("state") != "starting":
                print(f"VoiceInput engine: {state.get('state')} (pid={process.pid})")
                return 0
        except Exception:
            pass
        time.sleep(0.25)
    print("VoiceInput engine startup timed out", file=sys.stderr)
    return 1


def stop() -> int:
    pid = _read_pid()
    if not _alive(pid):
        print("VoiceInput engine is not running")
        return 0
    os.kill(pid, signal.SIGTERM)
    deadline = time.time() + 10
    while time.time() < deadline and _alive(pid):
        time.sleep(0.2)
    if _alive(pid):
        print(f"VoiceInput engine did not stop cleanly (pid={pid})", file=sys.stderr)
        return 1
    print("VoiceInput engine stopped")
    return 0


def status() -> int:
    pid = _read_pid()
    if not _alive(pid):
        print("VoiceInput engine: stopped")
        return 1
    try:
        state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        print(f"VoiceInput engine: running (pid={pid}), state unavailable")
        return 0
    print(f"VoiceInput engine: {state.get('state')} (pid={pid})")
    print(f"Model: {state.get('model_variant')}  Language: {state.get('language')}")
    if state.get("message"):
        print(state["message"])
    return 0


def doctor() -> int:
    checks = {
        "macOS": platform.system() == "Darwin",
        "Apple Silicon": platform.machine() == "arm64",
        "Python 3.13": sys.version_info[:2] == (3, 13),
        "Quartz": importlib.util.find_spec("Quartz") is not None,
        "sounddevice": importlib.util.find_spec("sounddevice") is not None,
        "mlx-qwen3-asr": importlib.util.find_spec("mlx_qwen3_asr") is not None,
        "8-bit model": model_is_complete("8bit"),
        "4-bit model": model_is_complete("4bit"),
    }
    for label, ok in checks.items():
        print(f"{'✓' if ok else '✗'} {label}")
    required = ["macOS", "Apple Silicon", "Python 3.13", "Quartz", "sounddevice", "mlx-qwen3-asr"]
    return 0 if all(checks[key] for key in required) else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="voiceinput")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("start", "stop", "restart", "status", "doctor"):
        subparsers.add_parser(command)
    install_parser = subparsers.add_parser("install-model")
    install_parser.add_argument("variant", choices=("8bit", "4bit"), default="8bit", nargs="?")
    install_parser.add_argument("--mirror", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "start":
        return start()
    if args.command == "stop":
        return stop()
    if args.command == "restart":
        result = stop()
        return start() if result == 0 else result
    if args.command == "status":
        return status()
    if args.command == "doctor":
        return doctor()
    if args.command == "install-model":
        return download(args.variant, args.mirror)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
