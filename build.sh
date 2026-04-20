#!/bin/bash
set -e

APP_NAME="HermesAgent"
DISPLAY_NAME="Hermes Agent"
BUILD_DIR=".build/release"
APP_BUNDLE="$DISPLAY_NAME.app"

# Derive version from the most recent git tag (e.g. v1.0.8 → 1.0.8).
# Falls back to "dev" if no tags exist, so the build never silently shows "1.0".
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "dev")

echo "→ Building..."
swift build -c release

echo "→ Bundling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

echo "→ Embedding Sparkle.framework..."
SPARKLE_FW=$(find .build/artifacts -name "Sparkle.framework" -maxdepth 6 | head -1)
if [ -z "$SPARKLE_FW" ]; then
    echo "Error: Sparkle.framework not found in .build/artifacts — run 'swift package resolve' first"
    exit 1
fi
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"

# Non-sandboxed apps MUST remove Sparkle's XPC services (per Sparkle docs).
# Shipping them causes "error launching the installer" on auto-update because
# Sparkle tries to use them but launchd rejects the XPC launch.
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
rm -f  "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/XPCServices"

# Fix rpath so the binary can find the embedded framework at runtime
install_name_tool \
    -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "→ Converting icon..."
ICONSET="AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "Hermes Icon.png" --out "$ICONSET/icon_16x16.png"
sips -z 32 32     "Hermes Icon.png" --out "$ICONSET/icon_16x16@2x.png"
sips -z 32 32     "Hermes Icon.png" --out "$ICONSET/icon_32x32.png"
sips -z 64 64     "Hermes Icon.png" --out "$ICONSET/icon_32x32@2x.png"
sips -z 128 128   "Hermes Icon.png" --out "$ICONSET/icon_128x128.png"
sips -z 256 256   "Hermes Icon.png" --out "$ICONSET/icon_128x128@2x.png"
sips -z 256 256   "Hermes Icon.png" --out "$ICONSET/icon_256x256.png"
sips -z 512 512   "Hermes Icon.png" --out "$ICONSET/icon_256x256@2x.png"
sips -z 512 512   "Hermes Icon.png" --out "$ICONSET/icon_512x512.png"
sips -z 1024 1024 "Hermes Icon.png" --out "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>ai.get-hermes.HermesAgent</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Hermes Agent uses the microphone for voice input in the chat interface.</string>
    <key>NSUserNotificationUsageDescription</key>
    <string>Hermes Agent notifies you when an AI response is ready while the window is in the background.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
    </dict>
    <key>SUPublicEDKey</key>
    <string>daAlTqdBbYPSCDjS9IfTCJOFDo1jqtjMRZluhtAbKMY=</string>
    <key>SUFeedURL</key>
    <string>https://hermes-webui.github.io/hermes-swift-mac/appcast.xml</string>
</dict>
</plist>
PLIST

echo "→ Signing (ad-hoc)..."
# Sign the framework first, then the app bundle.
# --entitlements embeds the plist so local builds match CI-signed DMGs.
# Note: ad-hoc signing (sign -) does not verify entitlements; use CI for notarized builds.
codesign --force --deep --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - --entitlements Entitlements.plist "$APP_BUNDLE"

echo "→ Installing to Applications..."
rm -rf "/Applications/$APP_BUNDLE"
cp -r "$APP_BUNDLE" "/Applications/$APP_BUNDLE"

echo "→ Installed to /Applications/$APP_BUNDLE"
echo "Note: icon cache refresh is optional and may require sudo if the old icon persists."
echo "If needed, run these commands manually:"
echo "  sudo find /private/var/folders -name \"com.apple.dock.iconcache\" -exec rm {} \\; 2>/dev/null || true"
echo "  sudo rm -rf /Library/Caches/com.apple.iconservices.store 2>/dev/null || true"
echo "  killall Dock"
echo "  killall Finder"

echo "✓ Done! Run with: open \"$APP_BUNDLE\""
