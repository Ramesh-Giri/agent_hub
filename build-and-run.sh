#!/bin/bash
set -e

APP_NAME="Canopy"
BUILD_DIR=".build/debug"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
# Find the best available code signing identity (prefer Apple Development, fall back to self-signed)
CERT_NAME=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    CERT_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Canopy Dev\|AgentHub Dev"; then
    CERT_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Canopy Dev\|AgentHub Dev" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

echo "Building $APP_NAME..."
swift build

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Canopy</string>
    <key>CFBundleDisplayName</key>
    <string>Canopy</string>
    <key>CFBundleIdentifier</key>
    <string>com.techkreator.Canopy</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Canopy</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Canopy needs screen capture permission to show live previews of your AI agent windows.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Canopy needs automation permission to interact with your AI agent windows.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign the app bundle
if [ -n "$CERT_NAME" ]; then
    echo "Signing with '$CERT_NAME' (stable identity)..."
    codesign --force --deep --sign "$CERT_NAME" --identifier "com.techkreator.Canopy" "$APP_BUNDLE"
else
    echo "Warning: No signing cert found, using ad-hoc (permissions won't persist across rebuilds)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "App bundle ready at: $APP_BUNDLE"
echo ""

if [ "$1" = "--install" ]; then
    echo "Installing to /Applications..."
    pkill -x Canopy 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_PATH"
    cp -R "$APP_BUNDLE" "$INSTALL_PATH"

    echo "Installed. If Screen Recording dialog appears, grant permission then relaunch."
    echo ""
    echo "Launching..."
    open "$INSTALL_PATH"
else
    echo "Launching from build dir (use --install to install to /Applications)..."
    open "$APP_BUNDLE"
fi
