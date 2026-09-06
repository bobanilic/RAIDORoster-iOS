#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Products/Release-iphoneos/RAIDORoster.app"
PAYLOAD="$ROOT/Payload"
IPA="$ROOT/RAIDORoster-unsigned.ipa"

rm -rf "$BUILD" "$PAYLOAD" "$IPA"

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
python3 "$ROOT/v213_patch.py"
python3 "$ROOT/v214_patch.py"
python3 "$ROOT/v2141_patch.py"
python3 "$ROOT/v2142_patch.py"
python3 "$ROOT/v215_patch.py"
python3 "$ROOT/v216_patch.py"
python3 "$ROOT/v2161_patch.py"
python3 "$ROOT/v217_patch.py"
python3 "$ROOT/v2171_fix.py"
python3 "$ROOT/v2172_fix.py"
python3 "$ROOT/v2173_fix.py"
python3 "$ROOT/v2174_fix.py"
python3 "$ROOT/v2175b_fix.py"
python3 "$ROOT/v2176_fix.py"
python3 "$ROOT/v2177_fix.py"
python3 "$ROOT/v2178_fix.py"
python3 "$ROOT/v2179_fix.py"
python3 "$ROOT/v2180_fix.py"
python3 "$ROOT/v2181_fix.py"
python3 "$ROOT/v2182_fix.py"
python3 "$ROOT/v2182b_fix.py"
python3 "$ROOT/v2182c_fix.py"
python3 "$ROOT/v219_probe.py"
python3 "$ROOT/v2191_probe.py"
python3 "$ROOT/v2192_probe.py"
python3 "$ROOT/v2193_feed_backend.py"
python3 "$ROOT/v2194_month_navigation_fix.py"
python3 "$ROOT/v2195_month_key_arithmetic_fix.py"
python3 "$ROOT/v2196_hybrid_position_engine.py"
python3 "$ROOT/v2197_fleet_intelligence.py"
python3 "$ROOT/v2197b_compile_fix.py"
python3 "$ROOT/v2197c_initializer_fix.py"
python3 "$ROOT/v2198_fleet_reliability.py"
python3 "$ROOT/v2199_announcements.py"
python3 "$ROOT/v2200_earnings.py"
python3 "$ROOT/v2201_daily_pay.py"
python3 "$ROOT/v2202_pay_policy.py"
python3 "$ROOT/v2203_raido_blh.py"

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
/usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string RAIDORoster can add your roster duties to Calendar when you ask it to." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSLocationWhenInUseUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSLocationWhenInUseUsageDescription string RAIDORoster uses your location to show your live position during a flight when you open Flight Companion." "$APP/Info.plist"

mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$IPA" Payload
)
rm -rf "$PAYLOAD"

echo "Unsigned IPA: $IPA"
