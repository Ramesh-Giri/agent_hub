#!/bin/bash
set -e

APP_NAME="Canopy"
BUILD_DIR=".build/debug"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
# Find the best available code signing identity.
# Use SHA-1 hash to avoid "ambiguous" errors when multiple certs have the same name.
CERT_SHA=""
CERT_NAME=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    CERT_SHA=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
    CERT_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Canopy Dev"; then
    CERT_SHA=$(security find-identity -v -p codesigning 2>/dev/null | grep "Canopy Dev" | head -1 | awk '{print $2}')
    CERT_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Canopy Dev" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

echo "Building $APP_NAME..."
swift build

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate .icns from icon PNGs
ICON_SRC="Sources/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET="$BUILD_DIR/AppIcon.iconset"
if [ -d "$ICON_SRC" ]; then
    echo "Generating app icon..."
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    cp "$ICON_SRC/icon_16x16.png"     "$ICONSET/icon_16x16.png"
    cp "$ICON_SRC/icon_16x16@2x.png"  "$ICONSET/icon_16x16@2x.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_32x32.png"
    cp "$ICON_SRC/icon_32x32@2x.png"  "$ICONSET/icon_32x32@2x.png"
    cp "$ICON_SRC/icon_128x128.png"   "$ICONSET/icon_128x128.png"
    cp "$ICON_SRC/icon_128x128@2x.png" "$ICONSET/icon_128x128@2x.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_256x256.png"
    cp "$ICON_SRC/icon_256x256@2x.png" "$ICONSET/icon_256x256@2x.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_512x512.png"
    cp "$ICON_SRC/icon_512x512@2x.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign the app bundle
if [ -n "$CERT_SHA" ]; then
    echo "Signing with '$CERT_NAME' (stable identity)..."
    codesign --force --deep --sign "$CERT_SHA" --identifier "com.techkreator.Canopy" "$APP_BUNDLE"
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
