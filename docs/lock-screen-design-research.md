# Lock Screen and notification design references

Reviewed 19 October 2026. Star counts are approximate snapshots, not quality guarantees.

| Project | License / approximate stars | Fit for RAIDO |
| --- | --- | --- |
| [WidgetExamples](https://github.com/pawello2222/WidgetExamples) | MIT / 1.1k | Useful public countdown, Live Activity, shared-view and Lock Screen examples. Reuse relevant patterns rather than importing the whole demo. |
| [AlertToast](https://github.com/elai950/AlertToast) | MIT / 2.4k | SwiftUI HUDs, banners and completion/error feedback inside RAIDO. Does not redesign the iOS Lock Screen. |
| [NotificationBanner](https://github.com/Daltron/NotificationBanner) | MIT / 4.9k | Customizable UIKit in-app banners and queuing. Less direct fit for RAIDO's SwiftUI views than AlertToast. |

Recommended direction: keep the existing ActivityKit/WidgetKit implementation,
use public WidgetExamples and Apple's Emoji Rangers sample for layout and
lifecycle reference, and keep the foreground content independent of the glass
background. A clearer type hierarchy, concise pickup/report details, consistent
precaution accents and restrained borders can improve the card without a new
runtime dependency. AlertToast is the best candidate if RAIDO later needs a
consistent presentation for in-app sync and review confirmations.

Regular notification banners are system-rendered. A notification content
extension can customize the expanded interface; it does not replace the
abbreviated banner. None of the in-app banner libraries changes that constraint.

The 2.29.23 patch adds no third-party dependency or copied source. Any later
source reuse must preserve the applicable license notices.

References:

- [Apple forum: glassEffect can hide widget text](https://developer.apple.com/forums/thread/789384)
- [Apple: Emoji Rangers sample](https://developer.apple.com/documentation/widgetkit/emoji-rangers-supporting-live-activities-interactivity-and-animations)
- [Apple: customizing notification appearance](https://developer.apple.com/documentation/usernotificationsui/customizing-the-appearance-of-notifications)
# Implemented follow-up — 2.29.24

AlertToast 1.3.9 is now vendored under `RAIDORoster/ThirdParty`, with its MIT
notice bundled as `ThirdPartyNotices.txt`. It handles in-app messages only.
The initial source adjustment permits narrow-screen wrapping in HUD/banner text.
ActivityKit continues to render native countdowns and background notifications.
Compact, Orbit and Focus share their foreground layout with the Settings sample.

## 2.29.25 findings and scoped adoption

AlertToast PR #112 remains open and unmerged. Its BackgroundModifier adds
glassEffect(in: .rect(cornerRadius: 16)) on iOS/macOS 26. The RAIDO adaptation
keeps Solid opaque, handles Reduce Transparency, and matches the capsule/rounded
rectangle effect to the existing toast shape. This is actual in-app glass; it
does not establish support in the Live Activity renderer.

Apple's glassEffect documentation and "Applying Liquid Glass to custom views"
describe the public SwiftUI API. WidgetKit's supported-views documentation excludes
UIViewRepresentable, so AlertToast's UIKit blur is not a Lock Screen solution.
Apple forum thread 789384 reports disappearing foreground with glassEffect, while
thread 797298 explains system-controlled widget rendering modes. Home Screen
clear/tinted widget appearance is not proof of the same capability in an
ActivityKit Lock Screen card. The UI now labels that fallback Frosted.

Apple's TimeDataSource/Text formatter APIs support native updating without an app
timer. Foundation's hourMinute(padHourToLength:roundSeconds:) supplies the HH:MM
pattern. Orbit explicitly reserves its digit width rather than relying on the
renderer to relayout archived timer text; the native future offset's sign is
excluded from the visible digit slot. Custom DiscreteFormatStyle types are avoided
because developers report failed decoding in Live Activity system renderers.
