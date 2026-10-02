#!/bin/zsh
# Double-click in Finder to start the remote. Quit it from the menu bar icon.
cd "$(dirname "$0")" || exit 1

APP="/Applications/LazyRemote.app"
[ -d "$APP" ] || APP=".build/dd/Build/Products/Debug/LazyRemote.app"

if [ ! -d "$APP" ]; then
  echo "Building…"
  xcodegen generate \
    && xcodebuild -project MacRemote.xcodeproj -scheme MacRemote \
         -configuration Debug -derivedDataPath .build/dd -quiet build \
    || { echo "build failed"; read -r; exit 1; }
  echo
fi

open "$APP" || { echo "could not start $APP"; read -r; exit 1; }
echo "LazyRemote is running — look for the d-pad icon in the menu bar."
