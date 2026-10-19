# Lock Screen duty countdowns — 2.29.20

## 2.29.25 Orbit bounds and in-app Liquid Glass

Orbit uses the system TimeDataSource duration offset with Foundation's padded
hour/minute pattern on iOS 18+. It rounds remaining partial minutes up and keeps
the five HH:MM glyphs in a measured, fixed-width slot. The future anchor's leading
minus sign is outside that slot; the digit area is clipped at its measured bounds.
The card's existing stale date/view handles expiry. No custom formatter type,
background timer or periodic ActivityKit update is introduced. The iOS 17 fallback
retains the original system timer with explicit width limits. Today/Tomorrow moves
to the Orbit header, keeping the clock inside the ring's curved lower edge.

The Lock Screen background control now says Frosted rather than Glass: it selects
the system Live Activity material and does not claim to force Liquid Glass there.
In-app notifications have an independent Glass/Solid setting. AlertToast's
background modifier uses SwiftUI glassEffect on iOS 26+, following the approach
in upstream PR #112, with the effect shape matching the HUD capsule or banner.
Solid stays opaque; Reduce Transparency uses an opaque fallback, and older iOS
versions retain material blur. This code runs in the app only, not WidgetKit.
Native Lock Screen Liquid Glass remains unresolved. Both in-app glass appearance
and the minute-only timer's locked/Always-On rendering require device validation.

## 2.29.24 compact styles and system background

Settings offers Compact (the default), Orbit and Focus. Existing card/circles
preferences retain their meaning. All three share the same minimum content
height, with the original Compact type sizes, tight Orbit spacing and a larger
Focus timer. Their common content, stale state and system Text countdown remain
shared. Accessibility text can grow rather than being clipped to a fixed card.

The extension no longer calls glassEffect or supplies a clear host background.
Glass leaves the Live Activity backdrop to iOS using activityBackgroundTint(nil),
while Solid and Reduce Transparency use an opaque midnight tint. Foreground
text/icons are independent of that backdrop, and the whole card is no longer
dimmed when isLuminanceReduced changes during locking. The Settings sample uses
regularMaterial; iOS controls the actual Lock Screen material. This is a revised
workaround for the reported disappearing foreground, still requiring device
verification. Changing style also updates an already running sample activity.

In-app messages use vendored AlertToast 1.3.9 (MIT), with its license included in
the app. A small local change allows narrow-screen text wrapping. Compact and
Orbit use the top HUD; Focus uses a bottom banner. Settings includes three sample
messages. Foreground duty reminders use one toast plus the existing notification
list/sound, without a duplicate system banner. Background reminders retain native
iOS delivery. New roster changes show an in-app notice; Mark as reviewed gives
an in-app confirmation. No Outlook connection or extra change notification is
created. No new Live Activity timer, GPS or background loop is introduced.

## 2.29.23 foreground rendering fix

Device feedback showed the glass surface rendering while all labels and timers
disappeared. The glass effect is now applied only to an empty background shape;
the foreground card content stays outside that effect in every appearance mode.
This also keeps the foreground view hierarchy stable when appearance changes.
Apple Developer Forums thread 789384 reports matching disappearing-text symptoms
with glassEffect in widgets. This is a targeted rendering workaround, not proof
that all WidgetKit glass behavior is fixed. The installed Lock Screen preview
still needs device validation. No new dependency, timer or background work is
introduced.

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


### 2.29.26 startup and idle efficiency

Production startup creates the tabs before restoring saved roster JSON. A shared detached task reads the cache; the main actor only installs the result. Restoration does not rewrite archives or migrate legacy JSON on disk. A clear/manual import wins over a pending read. Existing change-review entries remain available.

AlertToast still supplies message cards and their native material. RAIDO now aligns the card in a separate overlay leaf, bypassing the library's global-screen geometry/state wrapper. No toast surface is instantiated while idle, and a visible message owns a cancellable one-shot dismissal. Settings samples use the same presentation.

Automatic roster work is restricted to the current month, plus a month explicitly selected by the user. Persisted history queues, retry state for excluded months and discovered historical links cannot resume a bulk download. Existing saved months remain readable. Foreground entry has one maintenance path; unchanged reminder inputs are not rescheduled within five minutes. Roster/settings/timezone changes bypass that interval.

A focused simulator check now launches production ContentView (rather than only the preview root), taps tabs and Settings, presents/dismisses a sample message and returns from the background. Device startup, glass appearance and energy use still require actual device validation. These changes remove identifiable work; they do not establish a measured battery percentage.
