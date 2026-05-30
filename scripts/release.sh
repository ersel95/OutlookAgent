#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, ve OutlookAgent'ı .dmg paketle.
# Tag-driven CI tarafından kullanılır (.github/workflows/release.yml).
#
# Gerekli ENV:
#   SIGNING_IDENTITY  "Developer ID Application: Adın Soyadın (ABCDE12345)"
#   ASC_KEY_PATH      App Store Connect API .p8 path'i
#   ASC_KEY_ID        ASC API Key ID
#   ASC_ISSUER_ID     ASC Issuer ID
#   SU_PUBLIC_ED_KEY  Sparkle EdDSA public key (Info.plist'e gömülecek)
#
# Usage: scripts/release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>}"
: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${SU_PUBLIC_ED_KEY:?set SU_PUBLIC_ED_KEY}"

APP_NAME="OutlookAgent"
DIST="$(pwd)/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d)/$APP_NAME"

rm -rf "$DIST"
mkdir -p "$DIST"

# 1. SPM dependency'leri resolve et (Sparkle çek)
echo "→ swift package resolve"
swift package resolve

# 2. Versiyon damgalı + Sparkle key gömülü unsigned bundle üret.
#    build.sh INSTALL_DIR ile dist'e yazıyor ve framework'ü embed ediyor.
echo "→ build.sh release (v$VERSION)"
VERSION="$VERSION" \
SU_PUBLIC_ED_KEY="$SU_PUBLIC_ED_KEY" \
INSTALL_DIR="$DIST" \
SIGNING_IDENTITY="-" \
./build.sh release

# 3. Sparkle.framework'ün iç bileşenlerini inside-out Developer-ID ile imzala.
#    App outer sealing'inden önce her nested executable imzalanmış olmalı.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    SPV="$SPARKLE/Versions/B"
    # XPC services kendi entitlements'larını taşır (Downloader sandboxed) — koru.
    for xpc in "$SPV/XPCServices/Installer.xpc" "$SPV/XPCServices/Downloader.xpc"; do
        [[ -e "$xpc" ]] && codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements,requirements,flags \
            --sign "$SIGNING_IDENTITY" "$xpc"
    done
    [[ -e "$SPV/Autoupdate" ]] && codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$SPV/Autoupdate"
    [[ -e "$SPV/Updater.app" ]] && codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$SPV/Updater.app"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE"
fi

# 4. Outer app'i en son imzala (şimdi sealed Sparkle.framework'ü de seal eder).
codesign --force --options runtime --timestamp \
    --identifier "com.ersel.outlookagent" \
    --entitlements entitlements.plist \
    --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 5. App'i notarize et + staple (ticket'i embed → offline launch yorucu warning yok).
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
xcrun notarytool submit "$DIST/$APP_NAME.zip" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
rm -f "$DIST/$APP_NAME.zip"

# 6. Stapled app'i drag-to-install DMG'e paketle.
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 7. DMG'yi de notarize + staple ("downloaded" warning'i DMG üstünden de kalkar).
xcrun notarytool submit "$DMG" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"

echo "✓ $DMG"
shasum -a 256 "$DMG"
