#!/bin/bash
set -e

echo "=== Starting Church AI Translation Setup for macOS ==="

# 0. Check Administrator Privileges
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
    echo " This setup script must be run from an account with Administrator"
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

echo "[✓] Administrator privileges confirmed for user '$USER'."

# 1. Load Homebrew environment if installed
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -f "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# 2. Check or install Homebrew
if ! command -v brew &> /dev/null; then
    echo "[+] Installing Homebrew package manager..."
    echo "[+] You may be prompted for your administrator password by the installer:"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

BREW_PREFIX="$(brew --prefix)"
echo "[✓] Homebrew detected at: $BREW_PREFIX"

# 3. Check and fix Homebrew multi-user permissions if needed
NEEDS_BREW_FIX=0

for test_dir in "$BREW_PREFIX" "$BREW_PREFIX/bin" "$BREW_PREFIX/share" "$BREW_PREFIX/lib" "$BREW_PREFIX/etc" "$BREW_PREFIX/var/homebrew"; do
    if [ -d "$test_dir" ] && [ ! -w "$test_dir" ]; then
        NEEDS_BREW_FIX=1
        break
    fi
done

if [ -d "$BREW_PREFIX/Cellar" ] && [ ! -w "$BREW_PREFIX/Cellar" ]; then
    NEEDS_BREW_FIX=1
fi

if [ -d "$BREW_PREFIX/.git" ]; then
    if ! git -C "$BREW_PREFIX" rev-parse --is-inside-work-tree &>/dev/null; then
        NEEDS_BREW_FIX=1
    fi
fi

if [ "$NEEDS_BREW_FIX" -eq 1 ]; then
    echo ""
    echo "=================================================================="
    echo " [!] Multi-User Homebrew Configuration Detected"
    echo "=================================================================="
    echo " Homebrew was installed or configured under a different user."
    echo " Administrative credentials are required to grant '$USER' permission"
    echo " to manage packages and formulas."
    echo "=================================================================="
    echo "[+] Prompting for administrator credentials..."
    
    if ! sudo -v; then
        echo "[!] Authentication failed or cancelled. Cannot update Homebrew permissions."
        exit 1
    fi

    echo "[+] Updating Homebrew permissions for '$USER' (group 'admin')..."
    sudo mkdir -p "$BREW_PREFIX/Cellar" \
                  "$BREW_PREFIX/bin" \
                  "$BREW_PREFIX/etc" \
                  "$BREW_PREFIX/include" \
                  "$BREW_PREFIX/lib" \
                  "$BREW_PREFIX/opt" \
                  "$BREW_PREFIX/sbin" \
                  "$BREW_PREFIX/share" \
                  "$BREW_PREFIX/var/homebrew/locks" \
                  "$BREW_PREFIX/var/homebrew/linked" 2>/dev/null || true

    sudo chown -R "$USER:admin" "$BREW_PREFIX"
    sudo chmod -R g+rwx "$BREW_PREFIX"

    # Configure Git safe directory so Homebrew git operations succeed across accounts
    sudo git config --system --add safe.directory "$BREW_PREFIX" 2>/dev/null || true
    if [ -d "$BREW_PREFIX/Library/Taps" ]; then
        sudo git config --system --add safe.directory "$BREW_PREFIX/Library/Taps/*/*" 2>/dev/null || true
    fi
    git config --global --add safe.directory "$BREW_PREFIX" 2>/dev/null || true

    echo "[✓] Homebrew permissions successfully configured for '$USER'."
fi

# 4. Check and install required system formulas (Python, PortAudio, FFmpeg)
echo "[+] Checking required system formulas (python@3.11, portaudio, ffmpeg)..."
MISSING_FORMULAS=()

if ! command -v python3.11 &>/dev/null && ! brew list --formula python@3.11 &>/dev/null; then
    MISSING_FORMULAS+=("python@3.11")
fi

if ! brew list --formula portaudio &>/dev/null; then
    MISSING_FORMULAS+=("portaudio")
fi

if ! command -v ffmpeg &>/dev/null && ! brew list --formula ffmpeg &>/dev/null; then
    MISSING_FORMULAS+=("ffmpeg")
fi

if [ ${#MISSING_FORMULAS[@]} -eq 0 ]; then
    echo "[✓] All required system formulas (python@3.11, portaudio, ffmpeg) are already installed."
else
    echo "[+] Installing missing formula(s): ${MISSING_FORMULAS[*]}..."
    brew install "${MISSING_FORMULAS[@]}"
fi

# 5. Target execution directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "[+] Setting up project folder at $SCRIPT_DIR..."
cd "$SCRIPT_DIR"

VENV_DIR="$SCRIPT_DIR/venv"
MODELS_DIR="$VENV_DIR/models"
HF_CACHE_DIR="$MODELS_DIR/huggingface"
TORCH_CACHE_DIR="$MODELS_DIR/torch"
PIP_CACHE_DIR="$VENV_DIR/.cache/pip"

# Check if existing venv is owned by another user and not writable
if [ -d "$VENV_DIR" ] && [ ! -w "$VENV_DIR" ]; then
    echo "[!] Virtual environment at $VENV_DIR is not writable by current user '$USER'."
    echo "[+] Updating ownership of virtual environment to '$USER:admin'..."
    sudo chown -R "$USER:admin" "$VENV_DIR"
fi

if [ -d "$VENV_DIR" ]; then
    # Verify existing venv is functional (e.g. if the project folder was moved or renamed)
    if ! "$VENV_DIR/bin/python3" -c "import sys" &>/dev/null; then
        echo "[!] Existing virtual environment is invalid (project folder was moved or renamed)."
        echo "[+] Recreating virtual environment while preserving downloaded models..."
        if [ -d "$MODELS_DIR" ]; then
            TEMP_MODELS="$(mktemp -d)"
            mv "$MODELS_DIR" "$TEMP_MODELS/"
            rm -rf "$VENV_DIR"
            if command -v python3.11 &> /dev/null; then
                python3.11 -m venv "$VENV_DIR"
            else
                python3 -m venv "$VENV_DIR"
            fi
            mkdir -p "$VENV_DIR"
            mv "$TEMP_MODELS/models" "$MODELS_DIR"
            rm -rf "$TEMP_MODELS"
        else
            rm -rf "$VENV_DIR"
        fi
    else
        echo "[✓] Virtual environment already exists and is valid."
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "[+] Creating Python virtual environment..."
    if command -v python3.11 &> /dev/null; then
        python3.11 -m venv "$VENV_DIR"
    else
        python3 -m venv "$VENV_DIR"
    fi
fi

mkdir -p "$MODELS_DIR" "$HF_CACHE_DIR" "$TORCH_CACHE_DIR" "$PIP_CACHE_DIR"

# Configure cache and download directories inside venv
export HF_HOME="$HF_CACHE_DIR"
export TORCH_HOME="$TORCH_CACHE_DIR"
export PIP_CACHE_DIR="$PIP_CACHE_DIR"

# Activate Python virtual environment
source "$VENV_DIR/bin/activate"

# 4. Upgrade pip and install Python packages
echo "[+] Upgrading pip inside virtual environment..."
pip install --upgrade pip --quiet

echo "[+] Installing AI, Audio, Tokenizer, and TTS Python packages..."
pip install --upgrade torch torchvision torchaudio
pip install --upgrade sounddevice configparser numpy faster-whisper transformers piper-tts sentencepiece protobuf

# 5. Download Piper Latin American Spanish Voice Model & Config File
echo "[+] Checking for Latin American Spanish Piper TTS voice assets in venv/models..."

# Clean up / relocate any legacy voice model files from project root
for legacy_file in "$SCRIPT_DIR"/*.onnx "$SCRIPT_DIR"/*.onnx.json; do
    if [ -f "$legacy_file" ]; then
        echo "[+] Moving $(basename "$legacy_file") from project root to venv/models/..."
        mv "$legacy_file" "$MODELS_DIR/"
    fi
done

VOICE_MODEL="$MODELS_DIR/es_MX-ald-medium.onnx"
VOICE_CONFIG="$MODELS_DIR/es_MX-ald-medium.onnx.json"

if [ ! -f "$VOICE_MODEL" ]; then
    echo "[+] Downloading es_MX-ald-medium.onnx to venv/models..."
    curl -L -o "$VOICE_MODEL" https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_MX/ald/medium/es_MX-ald-medium.onnx
else
    echo "[✓] es_MX-ald-medium.onnx already exists in venv/models."
fi

if [ ! -f "$VOICE_CONFIG" ]; then
    echo "[+] Downloading es_MX-ald-medium.onnx.json to venv/models..."
    curl -L -o "$VOICE_CONFIG" https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_MX/ald/medium/es_MX-ald-medium.onnx.json
else
    echo "[✓] es_MX-ald-medium.onnx.json already exists in venv/models."
fi

# 6. Pre-cache Speech-to-Text and Translation AI Models
echo ""
echo "[+] Checking AI model caches (Whisper STT & NLLB Translation)..."
python3 -c "
import os, sys, warnings, logging
os.environ['HF_HOME'] = '$HF_CACHE_DIR'
os.environ['TORCH_HOME'] = '$TORCH_CACHE_DIR'
warnings.filterwarnings('ignore')
logging.getLogger('huggingface_hub').setLevel(logging.ERROR)

from faster_whisper import WhisperModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

print('[+] Checking Whisper Base model...')
WhisperModel('base.en', download_root='$MODELS_DIR/whisper')
print('[✓] Whisper Base model is cached in venv/models/whisper.')

print('[+] Checking NLLB-200 translation model...')
AutoTokenizer.from_pretrained('facebook/nllb-200-distilled-600M', cache_dir='$HF_CACHE_DIR')
AutoModelForSeq2SeqLM.from_pretrained('facebook/nllb-200-distilled-600M', cache_dir='$HF_CACHE_DIR')
print('[✓] NLLB-200 model is cached in venv/models/huggingface.')
"

# 7. Verify Tool Versions & System Capabilities
echo ""
echo "=== System Verification Check ==="
python3 -c "
import sys, torch, sounddevice as sd, faster_whisper, transformers, sentencepiece
print(f'Python Version:       {sys.version.split()[0]}')
print(f'PyTorch Version:      {torch.__version__}')
print(f'Apple Metal (MPS):    {torch.backends.mps.is_available()}')
print(f'Faster-Whisper:       Installed')
print(f'Transformers:         {transformers.__version__}')
print(f'SentencePiece:        Installed')
print(f'SoundDevice (Audio):  {sd.__version__}')
"

echo ""
echo "=== Setup Complete! ==="
echo "Your Mac is fully configured. You can now run:"
echo "  python3 configure_audio.py"
echo "  python3 translator.py"