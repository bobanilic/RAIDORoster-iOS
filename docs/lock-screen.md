# Lock Screen duty countdowns — 2.29.20

Settings → Lock Screen → Countdowns & precaution provides independent opt-in
pickup countdown and precaution controls. Both are off until enabled. Compact
and circular layouts use the same saved roster times. Frosted leaves the Live
Activity background to iOS; Solid supplies an opaque midnight background. System
accessibility and wallpaper rendering can change the frosted appearance.

The app bundles a WidgetKit extension and uses ActivityKit. iOS 26 can schedule
the next two cards locally, two hours before pickup/report, without network push,
server polling, GPS, or an app timer. Older iOS versions can start a card when
RAIDO is opened inside that two-hour window. The countdown is rendered by iOS.
There is no frequent-update entitlement or periodic Live Activity update loop.

Precaution mode schedules a local reminder one hour before the 12-hour cutoff
and another when the cutoff begins. This covers the earlier period outside the
Live Activity window. The Live Activity displays the active pre-duty status in
the final two-hour window, alongside pickup or a report reference. It never
claims alcohol is permitted after the countdown. At the reference time iOS marks
the card stale and it shows Scheduled time reached. On the next foreground sync,
expired, disabled, changed or deleted activities are ended immediately.

Opening RAIDO refreshes current-month data through the existing authenticated
cache downloader, at most once per five minutes per running instance. Roster
changes remain in-app and can be marked reviewed; no second Outlook-triggered
alert or email connection is created. Refreshing and notifications require the
normal iOS permissions/session state. Live Activities additionally require that
the installation method preserve and register the bundled widget extension;
container-based execution may not provide this. Settings includes an explicit
sample-data Lock Screen preview and a Stop preview action to test installation
support separately from real pickup availability.

The device release verifier requires an ARM64 widget extension, matching app and
extension versions, the WidgetKit extension point, and the configured URL scheme.
Unit checks cover optional/expired plans, shared pickup/precaution cards, elapsed
time scheduling, relocation-day filtering and legacy note cleanup. Actual power
consumption, wallpaper appearance, Always-On display and system scheduling still
require device validation. No percentage savings or zero-energy claim is made.
