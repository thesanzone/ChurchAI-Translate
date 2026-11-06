#!/bin/bash
# Builds "Church Translate.app" for Mac using Apple's Command Line Tools (no Xcode needed).
# Output: SwiftApp/build/Church Translate.app
set -e
cd "$( dirname "${BASH_SOURCE[0]}" )"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ChurchTranslate"

APP="build/Church Translate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChurchTranslate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Built-in Piper voice (only if ./fetch_piper.sh has been run)
VOICE_DIR="Vendor/vits-piper-es_MX-ald-medium"
if [ -f "$VOICE_DIR/es_MX-ald-medium.onnx" ]; then
    mkdir -p "$APP/Contents/Resources/piper"
    cp "$VOICE_DIR/es_MX-ald-medium.onnx" "$VOICE_DIR/tokens.txt" "$VOICE_DIR/MODEL_CARD" "$APP/Contents/Resources/piper/"
    cp -R "$VOICE_DIR/espeak-ng-data" "$APP/Contents/Resources/piper/"
    echo "Included the built-in Piper voice"
else
    echo "Note: Piper voice not found (run ./fetch_piper.sh); the app will use Apple voices"
fi

# Local (ad-hoc) signature so macOS will run it and remember microphone permission.
codesign --force --sign - "$APP"
echo "Built: $(pwd)/$APP"
