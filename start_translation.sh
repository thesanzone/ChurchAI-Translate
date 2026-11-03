#!/bin/bash
set -e

# Target project directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Ensure all cache and model downloads are saved inside venv
export HF_HOME="$SCRIPT_DIR/venv/models/huggingface"
export TORCH_HOME="$SCRIPT_DIR/venv/models/torch"
export PIP_CACHE_DIR="$SCRIPT_DIR/venv/.cache/pip"

echo "=================================================="
echo "    CHURCH AI TRANSLATION MASTER LAUNCHER"
echo "=================================================="

# 1. Validate & Setup Mac Environment
echo ""
echo "[Step 1/3] Validating system setup & dependencies..."
if [ -f "$SCRIPT_DIR/setup_mac.sh" ]; then
    bash "$SCRIPT_DIR/setup_mac.sh"
else
    echo "[!] Error: setup_mac.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Activate Python Virtual Environment
echo ""
echo "[+] Activating Python virtual environment..."
source "$SCRIPT_DIR/venv/bin/activate"

# 2. Configure Audio Hardware Mapping
echo ""
echo "[Step 2/3] Launching Audio Device Configurator..."
python3 "$SCRIPT_DIR/configure_audio.py"

# 3. Start Live Translation System
echo ""
echo "[Step 3/3] Starting Live AI Translation System..."
python3 "$SCRIPT_DIR/translator.py"