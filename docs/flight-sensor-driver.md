> Historical feature notes. The app now builds committed source directly; see [source-build.md](source-build.md).

# Flight Companion 2.26.0

The build applies `v2226_sensor_driver.py` after v2225. The patch reads the
checked-in manager/observer fragments and adds `FlightSensorPolicy.swift` to the
Xcode target. Regenerate from clean source; do not apply over the earlier,
unvalidated v2226 patch.

## Behavior

- Locking the screen retains an armed or active flight location session.
- Continuous, timestamped acceleration and cabin-pressure evidence can propose
  takeoff or landing. Current phase, session bounds and contradictory fresh
  GNSS/ADS-B are checked before accepting either event.
- Missing route progress rejects landing. Landing uses an arrival window based
  on actual takeoff and scheduled block duration, with a two-hour allowance and
  an absolute 18-hour limit. Armed sessions retain the existing departure gate.
- A running sector survives offline roster refreshes, omitted roster items and
  limited schedule revisions. Its route geometry does not change just because
  another duty card is visible.
- Session phase/timing and measured progress persist locally. A relaunch can
  resume an eligible saved session when location authorization permits it.
  Partial sensor evidence is never restored across process interruption.
- Completion stops standard location updates, network polling and motion /
  barometer observation. Completed sector keys are retained for seven days to
  prevent re-arming. Low-power roster/region monitoring remains available.
- Estimated positions never enter the measured trail. A sensor landing holds
  the estimated marker at the scheduled destination. After 25 minutes the
  session expires as `Session complete · estimated`; this does not assert an
  observed on-block time.

## Evidence and calibration

`FlightSensorPolicy.Thresholds` contains all detector thresholds. Defaults are
experimental and require calibration against actual flights. The policy uses
elapsed sample time for smoothing, rejects duplicate/delayed data and resets
continuity after sample gaps. It requires acceleration followed by sustained
cabin climb for takeoff, and sustained cabin descent followed by braking with
flat cabin pressure for landing. Renewed climb invalidates descent evidence.

The existing `sensor-evidence.jsonl` now records every motion sample, including
values below 0.08 g, and explicit accepted/rejected phase candidates. Writes
are batched every five seconds or 64 records and flushed when observation
stops. A process kill can lose the final buffered batch. Session restarts and
sensor failures are logged; source timestamps represent measurement time.

## Validation and device acceptance

The Swift policy replay suite covers positive takeoff/landing traces, motion
and pressure gaps, stale/duplicate deliveries, missing progress, contradictory
measurements, descent expiry, go-around pressure evidence and long/delayed
arrival windows. CI also builds the fully generated iOS application and
verifies the packaged version, executable and location/motion permissions.

For device acceptance, launch from the Home screen without an attached
debugger, authorize precise/background location and Motion & Fitness, and
establish the session at the gate before switching to airplane mode. Record
actual takeoff/landing times separately and compare to the evidence log after
arrival. Test screen lock, pocket/bag placement, rejected takeoff, go-around,
delayed departure and at least one subsequent sector.

Neither a successful build nor a synthetic replay proves reliable iOS
background delivery or real-flight detection accuracy. The route model is a
scheduled-route estimate, not a measured aircraft track.
