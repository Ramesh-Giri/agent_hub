#!/bin/bash
set -e

APP_NAME="AgentHub"
BUILD_DIR=".build/debug"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
CERT_NAME="AgentHub Dev"

# --- Ensure self-signed code signing certificate exists ---
# A stable signing identity means macOS TCC permissions (Screen Recording,
# Accessibility, Microphone) persist across rebuilds. Ad-hoc signing changes
# the CDHash every build, causing macOS to revoke all permissions.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo ""
    echo "=== First-time setup: Creating code signing certificate ==="
    echo "This ensures permissions persist across rebuilds."
    echo ""

    TMPDIR_CERT=$(mktemp -d)

    # Generate self-signed code signing cert (valid 10 years)
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$TMPDIR_CERT/key.pem" -out "$TMPDIR_CERT/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" 2>/dev/null

    # Package as PKCS12
    openssl pkcs12 -export \
        -out "$TMPDIR_CERT/cert.p12" \
        -inkey "$TMPDIR_CERT/key.pem" -in "$TMPDIR_CERT/cert.pem" \
        -passout pass:tmp 2>/dev/null

    # Import into login keychain
    security import "$TMPDIR_CERT/cert.p12" \
        -k ~/Library/Keychains/login.keychain-db \
        -P "tmp" \
        -T /usr/bin/codesign 2>/dev/null || true

    # Allow codesign to use the key without prompting each time.
    # This may silently fail if the keychain is locked — in that case
    # you'll see a system dialog on first sign. Click "Always Allow".
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "" \
        ~/Library/Keychains/login.keychain-db 2>/dev/null || true

    rm -rf "$TMPDIR_CERT"

    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        echo "Certificate '$CERT_NAME' created successfully."
    else
        echo "Warning: Certificate creation may have failed. Will fall back to ad-hoc signing."
    fi
    echo ""
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
    <string>AgentHub</string>
    <key>CFBundleDisplayName</key>
    <string>AgentHub</string>
    <key>CFBundleIdentifier</key>
    <string>com.techkreator.AgentHub</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>AgentHub</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AgentHub needs screen capture permission to show live previews of your AI agent windows.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentHub needs automation permission to interact with your AI agent windows.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AgentHub uses the microphone for voice commands to AI agent windows.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>AgentHub uses speech recognition to convert voice input into text commands.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AgentHub uses the local network so the iOS companion app can send commands.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_agenthub._tcp</string>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign with "AgentHub Dev" certificate for stable TCC identity.
# Falls back to ad-hoc if the cert isn't available.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing with '$CERT_NAME' certificate (stable identity)..."
    codesign --force --deep --sign "$CERT_NAME" --identifier "com.techkreator.AgentHub" "$APP_BUNDLE"
else
    echo "Warning: '$CERT_NAME' cert not found, using ad-hoc (permissions won't persist across rebuilds)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "App bundle ready at: $APP_BUNDLE"
echo ""

# Install to /Applications only if --install flag is passed
if [ "$1" = "--install" ]; then
    echo "Installing to /Applications..."
    pkill -x AgentHub 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_PATH"
    cp -R "$APP_BUNDLE" "$INSTALL_PATH"

    echo "Installed. If Screen Recording dialog appears, grant permission then relaunch."
    echo ""
    echo "Launching..."
    open "$INSTALL_PATH"
else
    # Just launch from build dir
    echo "Launching from build dir (use --install to install to /Applications)..."
    open "$APP_BUNDLE"
fi
