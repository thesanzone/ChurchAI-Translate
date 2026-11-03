#!/bin/bash
set -e

echo "=== Starting Church AI Translation Setup for macOS ==="

# 0. Load Homebrew environment if installed
if [ -f "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -f "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# 1. Check or install Homebrew
if ! command -v brew &> /dev/null; then
    echo "[+] Installing Homebrew package manager..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    echo "[✓] Homebrew is installed. Updating Homebrew..."
    brew update
fi

# 2. Install required system formulas via Homebrew
echo "[+] Installing/Updating system formulas (Python, PortAudio, FFmpeg)..."
brew install python@3.11 portaudio ffmpeg || brew upgrade python@3.11 portaudio ffmpeg

# 3. Target execution directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "[+] Setting up project folder at $SCRIPT_DIR..."
cd "$SCRIPT_DIR"

VENV_DIR="$SCRIPT_DIR/venv"
MODELS_DIR="$VENV_DIR/models"
HF_CACHE_DIR="$MODELS_DIR/huggingface"
TORCH_CACHE_DIR="$MODELS_DIR/torch"
PIP_CACHE_DIR="$VENV_DIR/.cache/pip"

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

# 6. Verify Tool Versions & System Capabilities
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