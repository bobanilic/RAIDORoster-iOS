#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Products/Release-iphoneos/RAIDORoster.app"
PAYLOAD="$ROOT/Payload"
IPA="$ROOT/RAIDORoster-unsigned.ipa"

# Fail early if two patch commands are accidentally joined by a literal
# escaped newline sequence. Build the token in pieces so this check cannot
# match its own source text.
bad_patch_join='\n''python3'
if grep -Fq "$bad_patch_join" "$0"; then
  echo "Malformed patch-chain newline detected in $0" >&2
  exit 2
fi

# Validate every root-level Python patch referenced by this script before
# mutating generated sources, so missing/garbled patch names fail clearly.
while IFS= read -r patch_script; do
  if [[ ! -f "$ROOT/$patch_script" ]]; then
    echo "Missing patch script: $ROOT/$patch_script" >&2
    exit 2
  fi
done < <(sed -n 's/^python3 "\$ROOT\/\([^"]*\.py\)"$/\1/p' "$0")

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
python3 "$ROOT/v2204_blh_compile_fix.py"
python3 "$ROOT/v2205_announcement_reader_polish.py"
python3 "$ROOT/v2206_announcement_reader_compact.py"
python3 "$ROOT/v2207_reader_layout.py"
python3 "$ROOT/v2208_midnight.py"
python3 "$ROOT/v2209_interactions.py"
python3 "$ROOT/v2210_documents.py"
python3 "$ROOT/v2211_crew_dedup.py"
# Capture the real pre-profile engine, including authoritative RAIDO BLH.
mkdir -p "$BUILD/validation"
swiftc "$ROOT/RAIDORoster/EarningsModels.swift" "$ROOT/../tests/PayProfileParityChecks.swift" -o "$BUILD/validation/legacy-parity"
"$BUILD/validation/legacy-parity" > "$BUILD/validation/legacy.json"
python3 "$ROOT/v2212_pay_profile.py"
python3 "$ROOT/v2213_pay_profile_compile_fix.py"
python3 "$ROOT/v2214_fleet_v2.py"
python3 "$ROOT/v2215_fleet_v2_compile_fix.py"
python3 "$ROOT/v2216_fleet_status_fusion.py"
python3 "$ROOT/v2217_fleet_photo_store_fix.py"
python3 "$ROOT/v2218a_fleet_recency.py"
python3 "$ROOT/v2218b_fleet_hierarchy.py"
python3 "$ROOT/v2219_flight_companion_reliability.py"
python3 "$ROOT/v2220_flight_companion_v2.py"
python3 "$ROOT/v2221_measured_trail_only.py"
python3 "$ROOT/v2222_roster_auto_arm.py"
python3 "$ROOT/v2222b_auto_arm_contentview_fix.py"
python3 "$ROOT/v2222c_return_measurement.py"
python3 "$ROOT/v2222d_today_and_future_crew_fix.py"
python3 "$ROOT/v2223_flight_companion_v3_shadow.py"
python3 "$ROOT/v2223_flight_companion_v3_observer.py"
python3 "$ROOT/v2224_contentview_scope_fix.py"
python3 "$ROOT/v2225_global_airport_index.py"
python3 "$ROOT/v2226_sensor_driver.py"
python3 "$ROOT/v2227_fleet_responsiveness.py"
python3 "$ROOT/v2228_ice_redesign.py"
python3 "$ROOT/v2229_dual_themes.py"
python3 "$ROOT/v2229b_flight_context_fix.py"
python3 "$ROOT/v2229c_map_polish.py"

bash "$ROOT/../tools/run_generated_checks.sh"

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
/usr/libexec/PlistBuddy -c "Add :NSLocationWhenInUseUsageDescription string RAIDORoster uses your location for Flight Companion position and automatic flight detection." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSLocationAlwaysAndWhenInUseUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSLocationAlwaysAndWhenInUseUsageDescription string RAIDORoster uses low-power background location near a rostered departure to arm Flight Companion automatically, then stops after the flight session." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSMotionUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSMotionUsageDescription string RAIDORoster uses Motion & Fitness sensors for Flight Companion phase detection and flight-state diagnostics." "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSFaceIDUsageDescription" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSFaceIDUsageDescription string RAIDORoster uses Face ID to unlock your private Crew Documents vault." "$APP/Info.plist"

for privacy_key in \
  NSCalendarsFullAccessUsageDescription \
  NSLocationWhenInUseUsageDescription \
  NSLocationAlwaysAndWhenInUseUsageDescription \
  NSMotionUsageDescription \
  NSFaceIDUsageDescription
do
  /usr/libexec/PlistBuddy -c "Print :$privacy_key" "$APP/Info.plist" >/dev/null || {
    echo "Required privacy key missing from packaged app: $privacy_key" >&2
    exit 1
  }
done

/usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes" "$APP/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string location" "$APP/Info.plist"

mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$IPA" Payload
)
rm -rf "$PAYLOAD"

echo "Unsigned IPA: $IPA"
