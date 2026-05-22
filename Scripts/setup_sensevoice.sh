#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/VoiceInput"
VENV_DIR="$APP_SUPPORT_DIR/sensevoice-venv"
PYTHON_BIN="$VENV_DIR/bin/python"
BOOTSTRAP_PYTHON="${SENSEVOICE_BOOTSTRAP_PYTHON:-}"

if [[ -z "$BOOTSTRAP_PYTHON" ]]; then
  for candidate in python3.11 python3.12 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      BOOTSTRAP_PYTHON="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ -z "$BOOTSTRAP_PYTHON" ]]; then
  echo "Python 3 was not found." >&2
  exit 1
fi

mkdir -p "$APP_SUPPORT_DIR"

if [[ ! -x "$PYTHON_BIN" ]]; then
  "$BOOTSTRAP_PYTHON" -m venv "$VENV_DIR"
fi

"$PYTHON_BIN" -m pip install --upgrade pip
"$PYTHON_BIN" -m pip install --upgrade funasr modelscope torch torchaudio soundfile
"$PYTHON_BIN" "$ROOT_DIR/Resources/sensevoice_transcribe.py" --warmup

echo "SenseVoice setup complete."
