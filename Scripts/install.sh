#!/usr/bin/env bash
# 一条命令建立外置 Python 运行环境、构建 VoiceInput.app，并安装备用 CLI。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/VoiceInput"
RUNTIME_DIR="$APP_SUPPORT/Runtime"
VENV="$RUNTIME_DIR/venv"
BIN_DIR="$HOME/.local/bin"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "VoiceInput requires macOS on Apple Silicon." >&2
    exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required. Install it with: brew install uv" >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR" "$APP_SUPPORT/Models" "$APP_SUPPORT/State" "$BIN_DIR"
if [[ ! -x "$VENV/bin/python" ]]; then
    uv venv --python 3.13 "$VENV"
fi
PYTHON_VERSION="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$PYTHON_VERSION" != "3.13" ]]; then
    echo "VoiceInput requires a Python 3.13 runtime; found $PYTHON_VERSION in $VENV." >&2
    exit 1
fi

uv pip install --python "$VENV/bin/python" -r "$PROJECT_DIR/Engine/requirements.txt"
make -C "$PROJECT_DIR" install-app
cp "$PROJECT_DIR/Scripts/voiceinput" "$BIN_DIR/voiceinput"
chmod +x "$BIN_DIR/voiceinput"

echo "✅ VoiceInput runtime and application installed."
echo "Models are managed in VoiceInput Settings → Model."
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "Optional: add $BIN_DIR to PATH to use the voiceinput diagnostic command."
fi
