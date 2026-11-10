#!/bin/bash
# Sestaví BunnyUploader a zabalí binárku do BunnyUploader.app (pravý macOS app bundle).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="BunnyUploader"
DEFAULT_BUNDLE_ID="net.bunnyuploader.BunnyUploader"
BUNDLE_ID="${BUNNY_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
# A different bundle id gets its own Keychain item, settings, and Application Support folder.
DISPLAY_NAME="${BUNNY_DISPLAY_NAME:-Bunny Stream Uploader}"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP_DIR="${BUNNY_APP_DIR:-$APP_NAME.app}"
case "$APP_DIR" in
    *.app) ;;
    *) echo "BUNNY_APP_DIR must end with .app: $APP_DIR" >&2; exit 1 ;;
esac
MACOS_DIR="$APP_DIR/Contents/MacOS"

RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "==> balím $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# App icon: Assets.car (Liquid Glass) and AppIcon.icns (fallback), compiled from
# Icon/AppIcon.icon by tools/make_icon.sh.
for icon_file in Assets.car AppIcon.icns; do
    if [ -f "Resources/$icon_file" ]; then
        cp "Resources/$icon_file" "$RESOURCES_DIR/$icon_file"
    fi
done

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
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
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
                <string>public.movie</string>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.avi</string>
            </array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key><string>Upload to Bunny</string>
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
    if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1; then
        echo "    signed"
    else
        echo "    signing failed, falling back to ad-hoc"
        codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
    fi
else
    echo "==> no signing identity found — ad-hoc signing"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 && echo "    ad-hoc signed"
fi

# Registrace do LaunchServices — aby Finder nabídl "Otevřít v aplikaci → BunnyUploader" pro mp4/mov.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
case "$APP_DIR" in
    /*) APP_PATH="$APP_DIR" ;;
    *) APP_PATH="$(pwd)/$APP_DIR" ;;
esac
# Only the main app registers (Finder "Open with" and the Quick Action); a test build stays out.
if [ -x "$LSREGISTER" ] && [ "$BUNDLE_ID" = "$DEFAULT_BUNDLE_ID" ]; then
    "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 && echo "==> zaregistrováno v LaunchServices"
fi

echo "==> hotovo: $APP_DIR"
echo "    spuštění: open $APP_DIR"
