#!/bin/bash
# Church AI Translation launcher.
#   ./start_translation.sh          -> run setup only if needed, then open the app window
#   ./start_translation.sh --setup  -> force a full setup/repair first
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Strip macOS quarantine flags from downloaded archive and ensure executables have +x permissions
xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.command 2>/dev/null || true

if [ "$EUID" -eq 0 ]; then
    echo " [!] Please do NOT run this script using 'sudo'."
    exit 1
fi

# Load Homebrew environment if installed
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -f "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Keep all model downloads inside the venv
export HF_HOME="$SCRIPT_DIR/venv/models/huggingface"
export TORCH_HOME="$SCRIPT_DIR/venv/models/torch"
export PIP_CACHE_DIR="$SCRIPT_DIR/venv/.cache/pip"

PY="$SCRIPT_DIR/venv/bin/python3"

is_installed() {
    [ -x "$PY" ] && "$PY" -c "import importlib.util as u, sys; sys.exit(0 if all(u.find_spec(m) for m in ['PySide6','sounddevice','faster_whisper','transformers','piper']) else 1)" &>/dev/null
}

if [ "$1" = "--setup" ] || ! is_installed; then
    echo "=================================================="
    echo "    CHURCH AI TRANSLATION — FIRST-TIME SETUP"
    echo "=================================================="
    echo " This installs everything the translator needs."
    echo " It needs an Administrator account and can take"
    echo " 10-20 minutes the first time."
    echo "=================================================="
    bash "$SCRIPT_DIR/setup_mac.sh"
fi

echo ""
echo "[+] Opening the Church AI Translation window..."
mkdir -p "$HOME/ChurchAI/logs"
exec "$PY" "$SCRIPT_DIR/app.py"
