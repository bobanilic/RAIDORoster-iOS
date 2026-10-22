# 2.29.29 performance and Live Activity appearance

The user confirmed 2.29.28 no longer freezes on Today. They also confirmed that
Live Activities work after enabling the iPhone permission. The remaining device
reports concern reduced smoothness on iPhone 17 Pro Max and the Lock Screen
material. This update preserves the working login, cache, request and countdown
paths.

## Rendering and maintenance

- `AppState.swift` owns the root's small availability projection. Only cache
  presence/restoration changes invalidate the welcome/briefing decision. Calendar
  selection, reminder status and download-related leaf updates are not forwarded
  to every tab. Flight-service updates still consume real incoming snapshots.
- `RosterTimestamp.swift` owns fixed UTC parsing, one immutable formatter and a
  bounded 2048-date NSCache. It retains the previous parsing semantics and never
  caches roster/session state. Compatibility and concurrent-use checks compare
  against the previous parser. A CI microbenchmark reports both implementations;
  it does not represent frame rate or measured device battery savings.
- The month calendar prepares its date lookup, move markers, day slots and today's
  key once for each body evaluation rather than recreating them in each day cell.
- Dynamic UIKit colours are reused by their actual dark/light colour pair in a
  bounded cache; switching palettes selects a different pair. Existing theme
  preferences and accessibility behaviour remain.
- The Settings sample keeps a stable reference time, and an unchanged ActivityKit
  content payload does not cause another system update.

A large mechanical file split would not itself reduce rendering costs. The
extracted files have explicit data/lifecycle responsibilities; unrelated services
and feature logic remain in place to reduce regression risk.

## Glass and dimmed displays

Glass is an explicit option alongside Frosted and Solid. On iOS 26+, native
`glassEffect` is applied only to an empty background; labels, native countdowns
and icons stay outside the effect. The extension uses a clear host tint for this
option so its surface is not covered by the default host background. Frosted
continues to use the system backdrop. Older OS versions use regular material.

Always-On dimming and Reduce Transparency select an opaque, high-contrast
background. The same foreground view remains present; no opacity animation,
privacy override, rasterized snapshot, GPS, polling or app countdown timer is
added. Full glass during reduced luminance is not promised. Actual locked,
dimmed and wallpaper rendering must be checked on the user's device.

The missing-foreground symptom is also reported in Apple's developer forum;
Apple DTS requested a bug report. The background separation and dimmed fallback
are a targeted workaround, not evidence that the system renderer bug is fixed.

## Validation

The previous 2.29.28 release and 56 native tests passed. Its UI job timed out in a
manual simulator-install operation before executing tests. The startup harness
now lets XCTest boot/install the app and runner together, matching the passing
native suite. Existing per-command/job deadlines remain; no retry loop is added.

2.29.29: local Python/syntax/diff checks pass. New Swift checks, native regression,
release compilation and UI checks are pending CI. Measured frame pacing, battery
consumption and locked/Always-On appearance are not verified by static checks.

## Primary references

- [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Apple: DateFormatter thread safety and caching guidance](https://developer.apple.com/documentation/foundation/dateformatter)
- [Apple: Live Activity lifecycle and local requests](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple: Reduced luminance and legibility](https://developer.apple.com/documentation/swiftui/environmentvalues/isluminancereduced)
- [Apple: Live Activities design guidance](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- [Apple Developer Forums: glassEffect can lose widget foreground text](https://developer.apple.com/forums/thread/789384)
