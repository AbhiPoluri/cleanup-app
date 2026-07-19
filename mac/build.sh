#!/bin/bash
# Build Cleanup as a standalone macOS menubar app
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/Cleanup.app"
MACOS="$OUT/Contents/MacOS"
RES="$OUT/Contents/Resources"

mkdir -p "$MACOS" "$RES"

cat > "$OUT/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.abhiram.cleanup</string>
    <key>CFBundleName</key>
    <string>Cleanup</string>
    <key>CFBundleExecutable</key>
    <string>Cleanup</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>Cleanup uses the camera to watch your whiteboard in Whiteboard mode.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Cleanup uses the microphone for voice input in Agent mode.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Cleanup uses speech recognition to transcribe your voice into agent instructions.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Clean Up Message</string>
            </dict>
            <key>NSMessage</key>
            <string>cleanUpMessage</string>
            <key>NSPortName</key>
            <string>Cleanup</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>NSStringPboardType</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Compiling..."
swiftc "$DIR/Cleanup.swift" \
    -o "$MACOS/Cleanup" \
    -framework Cocoa \
    -framework SwiftUI

# Sign with a STABLE identity when one exists ("Cleanup Dev Signing", self-signed,
# created once in the login keychain). Without this every rebuild is a brand-new
# app to macOS TCC — Accessibility/mic/camera/speech grants reset on every install
# and the user gets permission-prompted forever. Ad-hoc fallback keeps builds
# working on machines without the cert.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Cleanup Dev Signing"; then
    codesign --force --deep -s "Cleanup Dev Signing" \
        --identifier com.abhiram.cleanup "$OUT"
    echo "Signed: Cleanup Dev Signing (TCC grants persist across rebuilds)"
else
    codesign --force --deep -s - --identifier com.abhiram.cleanup "$OUT" 2>/dev/null || true
    echo "Signed: ad-hoc (no 'Cleanup Dev Signing' cert — permission grants will reset each rebuild)"
fi

echo "Built: $OUT"

# ./build.sh install → copy to /Applications (required for the right-click Service)
# and refresh the Services registry
if [ "$1" = "install" ]; then
    pkill -f Cleanup.app 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Cleanup.app
    cp -R "$OUT" /Applications/Cleanup.app
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    # unregister the build copy — two registered bundles with the same ID fight over the service port
    "$LSREG" -u "$OUT" 2>/dev/null || true
    "$LSREG" -f /Applications/Cleanup.app
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
    open /Applications/Cleanup.app
    echo "Installed + relaunched: /Applications/Cleanup.app"
else
    echo "Run: open '$OUT'   (or: bash build.sh install)"
fi
