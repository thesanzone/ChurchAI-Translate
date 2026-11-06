#!/bin/bash
# Downloads the Piper voice engine (sherpa-onnx) and the es_MX "ald" voice used by the
# Python app into SwiftApp/Vendor/. Run once before ./build_mac_app.sh.
# Without these files the Mac app still builds, but falls back to Apple's voices.
#
# Licensing: the engine includes eSpeak NG (GPL v3). See README.md "Piper voice & licensing".
set -e
cd "$( dirname "${BASH_SOURCE[0]}" )"

SHERPA_VERSION="1.13.8"   # 2.x removed the built-in eSpeak phonemizer that Piper voices need
VOICE="vits-piper-es_MX-ald-medium"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download"

mkdir -p Vendor
cd Vendor

LIBDIR="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-static-lib"
if [ ! -d "$LIBDIR/lib" ]; then
    echo "[+] Downloading Piper engine (sherpa-onnx ${SHERPA_VERSION}, ~20 MB)..."
    curl -fSL -o sherpa.tar.bz2 "$BASE/v${SHERPA_VERSION}/${LIBDIR}.tar.bz2"
    tar xjf sherpa.tar.bz2 && rm sherpa.tar.bz2
fi

# C module the Swift code imports
mkdir -p CSherpaOnnx/include
curl -fsSL -o CSherpaOnnx/include/c-api.h \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${SHERPA_VERSION}/sherpa-onnx/c-api/c-api.h"
echo '/* Empty: lets SwiftPM build the CSherpaOnnx module around c-api.h */' > CSherpaOnnx/shim.c
rm -f lib && ln -s "$LIBDIR/lib" lib

if [ ! -f "$VOICE/es_MX-ald-medium.onnx" ]; then
    echo "[+] Downloading Piper voice es_MX-ald-medium (~67 MB)..."
    curl -fSL -o voice.tar.bz2 "$BASE/tts-models/${VOICE}.tar.bz2"
    tar xjf voice.tar.bz2 && rm voice.tar.bz2
fi

echo "[✓] Piper engine and voice are in $(pwd)"
