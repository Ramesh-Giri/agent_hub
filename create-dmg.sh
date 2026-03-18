#!/bin/bash
set -e

APP_NAME="Canopy"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}-arm64"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_DIR=".build/dmg"
DMG_PATH=".build/${DMG_NAME}.dmg"

echo "Building $APP_NAME for release (Apple Silicon)..."
swift build -c release

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

# Sign with best available certificate
CERT_SHA=""
CERT_NAME=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    CERT_SHA=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
    CERT_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi

if [ -n "$CERT_SHA" ]; then
    echo "Signing with '$CERT_NAME'..."
    codesign --force --deep --sign "$CERT_SHA" --identifier "com.techkreator.Canopy" "$APP_BUNDLE"
else
    echo "Signing ad-hoc..."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Creating DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create symlink to /Applications for drag-and-drop install
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_DIR"

echo ""
echo "DMG created: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "To install: Open the DMG, drag Canopy to Applications."
