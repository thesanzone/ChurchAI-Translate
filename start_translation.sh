#!/bin/bash
set -e

# Target project directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Load Homebrew environment if installed
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -f "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Check Administrator Privileges
if [ "$EUID" -eq 0 ]; then
    echo ""
    echo "=================================================================="
    echo " [!] ERROR: Please do NOT run this script using 'sudo'."
    echo "=================================================================="
    echo " Homebrew and Python virtual environments must be run by a"
    echo " standard user account with administrative rights."
    echo " The script will automatically prompt you for your administrator"
    echo " password when elevated access is required."
    echo "=================================================================="
    exit 1
fi

IS_ADMIN=0
if command -v dsmemberutil &>/dev/null; then
    if dsmemberutil checkmembership -U "$USER" -G admin &>/dev/null; then
        IS_ADMIN=1
    fi
fi
if [ "$IS_ADMIN" -eq 0 ]; then
    if id -Gn "$USER" 2>/dev/null | grep -qw "admin"; then
        IS_ADMIN=1
    fi
fi

if [ "$IS_ADMIN" -ne 1 ]; then
    echo ""
    echo "=================================================================="
    echo " [!] ERROR: Administrator Privileges Required"
    echo "=================================================================="
    echo " This script must be run from an account with Administrator"
    echo " privileges on this Mac at this time."
    echo ""
    echo " Current user: '$USER' (Standard Account)"
    echo ""
    echo " Please log into a macOS Administrator account, or have an"
    echo " Administrator grant '$USER' admin rights in:"
    echo "   System Settings -> Users & Groups"
    echo "=================================================================="
    exit 1
fi

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