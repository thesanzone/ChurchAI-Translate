#!/bin/bash
# Regenerates every app icon file from make_icon.swift:
#   AppIcon.icns                          -> used by build_mac_app.sh (Mac app)
#   Assets.xcassets/AppIcon.appiconset/   -> used by the Xcode project (Mac + iPad)
#   AppIcon-1024.png                      -> preview / App Store artwork
set -e
cd "$( dirname "${BASH_SOURCE[0]}" )"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/make_icon" make_icon.swift

# macOS .icns
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    "$TMP/make_icon" "$ICONSET/icon_${s}x${s}.png" $s mac
    "$TMP/make_icon" "$ICONSET/icon_${s}x${s}@2x.png" $((s * 2)) mac
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
"$TMP/make_icon" AppIcon-1024.png 1024 mac

# Xcode asset catalog (iPad uses one full-bleed 1024 image; Mac uses the sized set)
SET="Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
"$TMP/make_icon" "$SET/ios-1024.png" 1024 ios
cp "$ICONSET"/icon_*.png "$SET/"
cat > Assets.xcassets/Contents.json <<'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF
cat > "$SET/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "ios-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
echo "Icons written to $(pwd)"
