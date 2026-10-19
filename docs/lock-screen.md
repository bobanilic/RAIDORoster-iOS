# Lock Screen duty countdowns — 2.29.20

## 2.29.22 lead times and glass surface

Show before pickup/report offers 2, 4, 6 or 8 hours; the default remains 2.
Changing the setting replaces pending schedules, and shortening the window
hides an early active card until its new scheduled start. iOS limits a Live
Activity to eight active hours, so no permanent-card option is offered.
Precaution reminders still cover the earlier period outside the card window.

Glass uses SwiftUI's native glass effect on iOS 26, with an ultra-thin material
fallback on older iOS and an opaque background when Reduce Transparency is on.
The extension requests a clear host background so it does not cover the surface.
The Settings sample shares the same card surface. The circular timer explicitly
centers its text inside the ring. The optional countdown start field preserves
decoding of cards created before this update. Device wallpaper, accessibility
and Lock Screen rendering still require a preview check on the installed app.

## 2.29.21 installation and responsiveness fixes

The Status section checks whether the installed app still contains its widget
extension. If SideStore removed it, import the original IPA over the existing app
and keep app extensions. The extension must also be signed and registered; merely
finding the bundled file cannot establish that iOS accepted its registration.
Use Preview on Lock Screen for an immediate five-minute test, independent of any
roster pickup. These cards are Live Activities and do not appear in Add Widgets.

Lock Screen refresh skips roster parsing when both options are off. Enabled
cards use only upcoming rows instead of parsing every archived month. Parsed
priority events are reused until the roster, local day window or device time
zone changes; visibility and countdown state are still evaluated against the
current time. Duplicate Settings refreshes are removed. These changes reduce
work, but device responsiveness and power consumption still require measurement.

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
