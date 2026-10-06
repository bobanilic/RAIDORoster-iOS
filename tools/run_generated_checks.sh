#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../RAIDORoster-Web2IPA" && pwd)"
CHECKS="$ROOT/build/validation"
mkdir -p "$CHECKS"
swiftc "$ROOT/RAIDORoster/AppearanceModels.swift" "$ROOT/../tests/AppearanceChecks.swift" -o "$CHECKS/appearance"
"$CHECKS/appearance"
python3 "$ROOT/../tests/offline_land_checks.py" "$ROOT/RAIDORoster/OfflineLand.json"
swiftc -parse-as-library "$ROOT/../tests/AirportClockChecks.swift" -o "$CHECKS/airport-clocks"
"$CHECKS/airport-clocks" "$ROOT/RAIDORoster/AirportTimeZones.json"

python3 "$ROOT/../tools/check_fleet_refresh_store.py"
python3 "$ROOT/../tools/check_announcement_selection.py"
swiftc "$ROOT/RAIDORoster/FlightTrackingStatus.swift" "$ROOT/../tests/FlightTrackingStatusChecks.swift" -o "$CHECKS/gps-status"
"$CHECKS/gps-status"
swiftc "$ROOT/RAIDORoster/MapPresentationPolicy.swift" "$ROOT/../tests/MapPresentationChecks.swift" -o "$CHECKS/map-presentation"
"$CHECKS/map-presentation" "$ROOT/RAIDORoster/OfflinePlaceLabels.json"

# The patch chain changes these models. Check the exact generated sources too.
run_check() {
  local name="$1"
  shift
  swiftc "$@" "$ROOT/../tests/$name.swift" -o "$CHECKS/$name"
  "$CHECKS/$name" "$ROOT/RAIDORoster/GetJetAnnouncements.json"
}
run_check FlightSensorPolicyChecks "$ROOT/RAIDORoster/FlightSensorPolicy.swift"
run_check FleetRefreshChecks "$ROOT/RAIDORoster/FleetTrackingPolicy.swift" "$ROOT/RAIDORoster/FleetRefreshPolicy.swift"
run_check FleetTrackingPolicyChecks "$ROOT/RAIDORoster/FleetTrackingPolicy.swift"
run_check AnnouncementChecks "$ROOT/RAIDORoster/AnnouncementModels.swift"
run_check EarningsChecks "$ROOT/RAIDORoster/EarningsModels.swift" "$ROOT/RAIDORoster/PayProfileModels.swift"
run_check PayProfileChecks "$ROOT/RAIDORoster/EarningsModels.swift" "$ROOT/RAIDORoster/PayProfileModels.swift"
run_check CrewDocumentChecks "$ROOT/RAIDORoster/CrewDocumentVault.swift"

swiftc -D PAY_PROFILE "$ROOT/RAIDORoster/EarningsModels.swift" \
  "$ROOT/RAIDORoster/PayProfileModels.swift" "$ROOT/../tests/PayProfileParityChecks.swift" \
  -o "$CHECKS/pay-profile-parity"
"$CHECKS/pay-profile-parity" > "$CHECKS/profile.json"
python3 - "$CHECKS" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
legacy = json.loads((root / 'legacy.json').read_text())
profile = json.loads((root / 'profile.json').read_text())
if legacy != profile:
    raise SystemExit('FAIL: generated default Pay Profile differs from pre-profile earnings')
print(f'Passed legacy/default Pay Profile parity: {len(legacy)} synthetic scenarios')
PY
