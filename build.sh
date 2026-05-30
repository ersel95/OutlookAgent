#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="OutlookAgent"
APP_DISPLAY="Outlook Agent"
BUNDLE_ID="com.ersel.outlookagent"

echo "→ Swift derleniyor ($CONFIG)…"
swift build -c "$CONFIG"

BUILD_DIR=".build/$CONFIG"

# If /Applications/OutlookAgent.app exists, update it there (stable TCC path).
# Otherwise build in-place. Override with INSTALL_DIR=/path/to/dir.
if [ -z "${INSTALL_DIR:-}" ]; then
    if [ -d "/Applications/$APP_NAME.app" ]; then
        INSTALL_DIR="/Applications"
    else
        INSTALL_DIR="$(pwd)"
    fi
fi
APP_DIR="$INSTALL_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "→ .app bundle güncelleniyor: $APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# In-place replace executable only — keeps bundle inode + TCC mapping stable.
cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME.new"
mv -f "$CONTENTS/MacOS/$APP_NAME.new" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# Refresh resource bundle (AppleScripts may have changed)
rm -rf "$CONTENTS/Resources/${APP_NAME}_${APP_NAME}.bundle"

# Resource bundle (contains AppleScript files for Bundle.module to find)
if [ -d "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$CONTENTS/Resources/"
fi

# App icon (regenerate if missing)
if [ ! -f "AppIcon.icns" ] && [ -f "icon-1024.png" ]; then
    echo "→ AppIcon.icns regenerating from icon-1024.png…"
    rm -rf AppIcon.iconset && mkdir AppIcon.iconset
    sips -z 16 16     icon-1024.png --out AppIcon.iconset/icon_16x16.png > /dev/null
    sips -z 32 32     icon-1024.png --out AppIcon.iconset/icon_16x16@2x.png > /dev/null
    sips -z 32 32     icon-1024.png --out AppIcon.iconset/icon_32x32.png > /dev/null
    sips -z 64 64     icon-1024.png --out AppIcon.iconset/icon_32x32@2x.png > /dev/null
    sips -z 128 128   icon-1024.png --out AppIcon.iconset/icon_128x128.png > /dev/null
    sips -z 256 256   icon-1024.png --out AppIcon.iconset/icon_128x128@2x.png > /dev/null
    sips -z 256 256   icon-1024.png --out AppIcon.iconset/icon_256x256.png > /dev/null
    sips -z 512 512   icon-1024.png --out AppIcon.iconset/icon_256x256@2x.png > /dev/null
    sips -z 512 512   icon-1024.png --out AppIcon.iconset/icon_512x512.png > /dev/null
    cp icon-1024.png  AppIcon.iconset/icon_512x512@2x.png
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
fi
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Outlook Agent gelen mailleri okumak ve taslak yanıt oluşturmak için Microsoft Outlook'a erişir.</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Stable ad-hoc signature + Hardened Runtime + entitlements.
# Hardened Runtime + a stable identifier is what TCC needs to remember
# permissions across launches without re-prompting every time.
ENTITLEMENTS_FILE="entitlements.plist"
if [ -f "$ENTITLEMENTS_FILE" ]; then
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        --timestamp=none \
        "$APP_DIR"
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

# Strip Gatekeeper quarantine so macOS treats this as a known-by-the-user app.
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "✓ Bitti: $APP_DIR"
