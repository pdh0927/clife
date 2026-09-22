#!/bin/bash
# Builds Clife.app from source.
# Signs locally with a free "Apple Development" certificate if Xcode has one set
# up on this Mac (Xcode > Settings > Accounts); if not, falls back to ad-hoc
# signing ("-"), which needs no certificate at all. Either way the result is
# unsigned/ad-hoc for Gatekeeper purposes -- this project intentionally does not
# pursue a paid Developer ID + notarization. See README for the Gatekeeper
# workaround (right-click > Open) that users of the built app will need once.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Clife.app"

if [ -n "$SIGN_IDENTITY" ]; then
  : # explicit override from the environment
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  SIGN_IDENTITY="Apple Development"
else
  SIGN_IDENTITY="-"
fi

rm -r -f "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Supplied dog art, if there is any. The app falls back to drawing the dog when
# this directory is absent, so an empty assets/ is a valid state rather than a
# broken build.
[ -d "$DIR/assets/dog" ] && cp -R "$DIR/assets/dog" "$APP/Contents/Resources/dog"

swiftc -O \
  -o "$APP/Contents/MacOS/Clife" \
  "$DIR/src/main.swift" "$DIR/src/dog.swift" "$DIR/src/widget.swift"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "Built: $APP"
