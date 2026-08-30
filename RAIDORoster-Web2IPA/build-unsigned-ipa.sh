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
python3 "$ROOT/v2101_patch.py"
python3 "$ROOT/v2102_patch.py"
python3 "$ROOT/v211_pre.py"
python3 "$ROOT/v211_patch.py"
python3 "$ROOT/v211_post.py"
python3 "$ROOT/v211_swift_fix.py"
python3 "$ROOT/v2111_patch.py"
python3 "$ROOT/v2112_patch.py"
python3 "$ROOT/v2113_patch.py"
python3 "$ROOT/v2114_patch.py"
python3 "$ROOT/v2114_cleanup.py"
python3 "$ROOT/v2115_patch.py"
python3 "$ROOT/v2116_patch.py"
python3 "$ROOT/v2117_patch.py"
python3 "$ROOT/v2117b_patch.py"
python3 "$ROOT/v2118_patch.py"
python3 "$ROOT/v2119_patch.py"
python3 "$ROOT/v21110_patch.py"
python3 "$ROOT/v21111_patch.py"
python3 "$ROOT/v21112_patch.py"
python3 "$ROOT/v21113_patch.py"
# V2.12 / V2.12.1 / V2.12.2 were visual-theme experiments. V2.13
# intentionally returns to the approved classic V2.11.13 visual base.
python3 "$ROOT/v213_patch.py"
python3 "$ROOT/v214_patch.py"
python3 "$ROOT/v2141_patch.py"
python3 "$ROOT/v2142_patch.py"
python3 "$ROOT/v215_patch.py"
python3 "$ROOT/v216_patch.py"
python3 "$ROOT/v2161_patch.py"
python3 "$ROOT/v217_patch.py"

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

/usr/libexec/PlistBuddy -c "Delete :NSCalendarsFullAccessUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string Allow RAIDO Roster to add and update your duty schedule in Calendar." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSCalendarsUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSCalendarsUsageDescription string Allow RAIDO Roster to add and update your duty schedule in Calendar." "$APP/Info.plist"

python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    plist = plistlib.load(handle)
plist["NSLocationWhenInUseUsageDescription"] = (
    "Allow RAIDO Roster to use your location only while Live GPS tracking "
    "is active on the Today route map."
)
with open(path, "wb") as handle:
    plistlib.dump(plist, handle, fmt=plistlib.FMT_BINARY)
PY

mkdir -p "$ROOT/Payload"
cp -R "$APP" "$ROOT/Payload/"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$IPA" Payload
)
rm -rf "$ROOT/Payload"

echo "Unsigned IPA created: $IPA"
echo "Sign/install it with SideStore, AltStore, Sideloadly, or your Apple certificate workflow."
