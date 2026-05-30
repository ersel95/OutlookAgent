#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="OutlookAgent"
APP_DISPLAY="Outlook Agent"
BUNDLE_ID="com.ersel.outlookagent"

# Version stamping. Tag-driven CI sets VERSION="1.2.3"; local dev defaults to 0.0.0
# so Sparkle always sees a higher number in the appcast (= updates fire correctly).
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"

# Sparkle config — public EdDSA key embedded in Info.plist. Private key lives in
# GitHub Secrets (SPARKLE_ED_PRIVATE_KEY); see CLAUDE.md "Release" bölümü.
SU_FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/ersel95/OutlookAgent/main/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}"

echo "→ Swift derleniyor ($CONFIG, v$VERSION)…"
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
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

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

# Sparkle.framework embed. SPM çekiyor ama otomatik bundle'a koymuyor —
# .build/artifacts altındaki XCFramework'ten macos slice'ı kopyalıyoruz.
SPARKLE_SRC="$(find .build -type d -path '*/Sparkle.xcframework/*-arm64_x86_64/Sparkle.framework' -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_SRC" ]; then
    SPARKLE_SRC="$(find .build -type d -name 'Sparkle.framework' -print -quit 2>/dev/null || true)"
fi
if [ -n "$SPARKLE_SRC" ] && [ -d "$SPARKLE_SRC" ]; then
    echo "→ Sparkle.framework embed: $SPARKLE_SRC"
    rm -rf "$CONTENTS/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_SRC" "$CONTENTS/Frameworks/Sparkle.framework"
else
    echo "⚠️  Sparkle.framework bulunamadı — auto-update çalışmaz. 'swift package resolve' önce."
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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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
    <key>SUFeedURL</key>
    <string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SU_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

# Codesign. CI passes SIGNING_IDENTITY="Developer ID Application: ..." ve
# Sparkle inside-out imzayı scripts/release.sh hallediyor — burada local ad-hoc.
SIGN_ID="${SIGNING_IDENTITY:--}"
TIMESTAMP_FLAG="--timestamp=none"
if [ "$SIGN_ID" != "-" ]; then
    TIMESTAMP_FLAG="--timestamp"
fi

# Local dev'de Sparkle.framework iç bileşenlerini de ad-hoc imzala — yoksa
# Gatekeeper bundle'ı reddediyor ve "damaged" hatası veriyor.
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ] && [ "$SIGN_ID" = "-" ]; then
    SPV="$SPARKLE/Versions/B"
    for xpc in "$SPV/XPCServices/Installer.xpc" "$SPV/XPCServices/Downloader.xpc"; do
        [ -e "$xpc" ] && codesign --force --sign - "$xpc" 2>/dev/null || true
    done
    [ -e "$SPV/Autoupdate" ] && codesign --force --sign - "$SPV/Autoupdate" 2>/dev/null || true
    [ -e "$SPV/Updater.app" ] && codesign --force --sign - "$SPV/Updater.app" 2>/dev/null || true
    codesign --force --sign - "$SPARKLE" 2>/dev/null || true
fi

# Stable ad-hoc signature + Hardened Runtime + entitlements.
# Hardened Runtime + a stable identifier is what TCC needs to remember
# permissions across launches without re-prompting every time.
ENTITLEMENTS_FILE="entitlements.plist"
if [ -f "$ENTITLEMENTS_FILE" ]; then
    codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        $TIMESTAMP_FLAG \
        "$APP_DIR"
else
    codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_DIR"
fi

# Strip Gatekeeper quarantine so macOS treats this as a known-by-the-user app.
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "✓ Bitti: $APP_DIR (v$VERSION)"
