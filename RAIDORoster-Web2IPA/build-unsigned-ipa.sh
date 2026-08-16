#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Products/Release-iphoneos/RAIDORoster.app"
IPA="$ROOT/RAIDORoster-unsigned.ipa"

rm -rf "$BUILD" "$ROOT/Payload" "$IPA"
mkdir -p "$BUILD/Products" "$BUILD/Intermediates"

python3 "$ROOT/v25_patch.py"
python3 "$ROOT/v26_patch.py"
python3 "$ROOT/v27_patch.py"
python3 "$ROOT/v28_patch.py"
python3 "$ROOT/v29b_patch.py"
python3 "$ROOT/v29c_fix.py"
python3 "$ROOT/v210_patch.py"

xcodebuild \
  -project "$ROOT/RAIDORoster.xcodeproj" \
  -target RAIDORoster \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$BUILD/Products" \
  OBJROOT="$BUILD/Intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP" ]]; then
  echo "Build completed but app bundle was not found at: $APP" >&2
  exit 1
fi

# Xcode's generated plist does not reliably materialize custom INFOPLIST_KEY_*
# values in unsigned command-line builds. Inject the EventKit purpose strings
# into the final unsigned bundle before SideStore/AltStore signs it.
/usr/libexec/PlistBuddy -c "Delete :NSCalendarsFullAccessUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string Allow RAIDO Roster to add and update your duty schedule in Calendar." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSCalendarsUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSCalendarsUsageDescription string Allow RAIDO Roster to add and update your duty schedule in Calendar." "$APP/Info.plist"

mkdir -p "$ROOT/Payload"
cp -R "$APP" "$ROOT/Payload/"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$IPA" Payload
)
rm -rf "$ROOT/Payload"

echo "Unsigned IPA created: $IPA"
echo "Sign/install it with SideStore, AltStore, Sideloadly, or your Apple certificate workflow."
