#!/bin/sh
# Wraps the CLI in a .app bundle so it has a stable code identity.
# macOS will not let an ad-hoc binary with a hash-derived identifier post key events.
set -e

cd "$(dirname "$0")/.."
swift build

APP=".build/MacRemote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/remotectl "$APP/Contents/MacOS/MacRemote"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.altay.macremote</string>
	<key>CFBundleName</key>
	<string>MacRemote</string>
	<key>CFBundleExecutable</key>
	<string>MacRemote</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Used to let your iPhone connect to this Mac and send remote control button presses.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.altay.macremote "$APP"
echo "built $APP"
echo "run: $APP/Contents/MacOS/MacRemote keytest MID --delay 3"
