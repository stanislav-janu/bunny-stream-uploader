#!/bin/bash
# Sestaví BunnyUploader a zabalí binárku do BunnyUploader.app (pravý macOS app bundle).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="BunnyUploader"
BUNDLE_ID="${BUNNY_BUNDLE_ID:-net.bunnyuploader.BunnyUploader}"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP_DIR="$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "==> balím $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# App ikona (Bunny logo)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Lokalizace (en, cs, hu, pl, de) do app bundle (Bundle.main najde .lproj)
if [ -d "Resources/Localizations" ]; then
    cp -R Resources/Localizations/*.lproj "$RESOURCES_DIR/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Bunny Stream Uploader</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>cs</string>
        <string>hu</string>
        <string>pl</string>
        <string>de</string>
    </array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
            </array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key><string>Upload do Bunny</string>
            </dict>
            <key>NSMessage</key><string>uploadToBunny</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Code signing. A stable signing identity keeps the keychain "Always Allow"
# decision valid across rebuilds (the designated requirement stays the same).
# Set BUNNY_SIGN_IDENTITY to your identity, or the script auto-detects the first
# available one, or falls back to ad-hoc signing so the app still runs locally.
if [ -n "${BUNNY_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$BUNNY_SIGN_IDENTITY"
else
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -1)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> signing ($SIGN_IDENTITY)"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1 \
        && echo "    signed" \
        || echo "    signing failed, falling back to ad-hoc" && codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
else
    echo "==> no signing identity found — ad-hoc signing"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 && echo "    ad-hoc signed"
fi

# Registrace do LaunchServices — aby Finder nabídl "Otevřít v aplikaci → BunnyUploader" pro mp4/mov.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$(pwd)/$APP_DIR" >/dev/null 2>&1 && echo "==> zaregistrováno v LaunchServices"
fi

echo "==> hotovo: $APP_DIR"
echo "    spuštění: open $APP_DIR"
