#!/bin/zsh
# Builds a Developer ID signed, notarized, stapled LazyRemote.dmg in .build/release/.
# Requires a Developer ID Application cert for the team and a notarytool keychain profile.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="ZRG87YTBFL"
NOTARY_PROFILE="${NOTARY_PROFILE:-lazyremote-notary}"
OUT=".build/release"
ARCHIVE="$OUT/LazyRemote.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/LazyRemote.app"
VERSION=$(grep 'CFBundleShortVersionString' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
DMG="$OUT/LazyRemote-$VERSION.dmg"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notary profile '$NOTARY_PROFILE' not found. Create it once with:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID"
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate
xcodebuild -project MacRemote.xcodeproj -scheme MacRemote -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -quiet archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet

codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize and staple the app itself so it passes Gatekeeper offline once copied out of the DMG.
ditto -c -k --keepParent "$APP" "$OUT/LazyRemote.zip"
xcrun notarytool submit "$OUT/LazyRemote.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LazyRemote" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Ready to distribute: $DMG"
