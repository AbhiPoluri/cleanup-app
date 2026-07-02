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
