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
# Swear-word filter list, shared with the Python app (edit ../word_filter.txt, then rebuild)
cp ../word_filter.txt "$APP/Contents/Resources/word_filter.txt"

# Local (ad-hoc) signature so macOS will run it and remember microphone permission.
codesign --force --sign - "$APP"
echo "Built: $(pwd)/$APP"
