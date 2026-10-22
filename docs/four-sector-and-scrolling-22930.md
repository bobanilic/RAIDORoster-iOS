# 2.29.30: complete day briefings and scrolling work

The supplied recording shows four route buttons (DI9003, DI6656, DI6657,
DI9004), but only three sectors in the selected-day heading and duty agenda.
The portal extractor splits the 15:05–19:10 gap into two duty envelopes.
The map already collected all envelopes for the date; the heading and agenda
used only the first envelope. No sectors were deleted from the saved cache.

`RosterDayPresentation` selects all envelopes on the same date, removes repeated
item IDs and orders them chronologically. Calendar day briefings and Today
agendas display every envelope, with separate report/release and export actions.
The map and calendar count share one sector policy, including air positioning.
Duty timing, priority selection, relocation handling, reminders and cache schemas
remain intact. This repairs existing cached data without a new login/import.

For scrolling, the app now opts into the full ProMotion range via Apple's
`CADisableMinimumFrameDurationOnPhone` key. iOS still controls adaptive frame
pacing; there is no display link or forced refresh loop. Card shadows apply to
the rounded background only. Each agenda sorts its activities once per body;
historical route geometry inputs are prepared once per body. Saved GPS trail
reads/decoding run on a cancellable utility task and cannot publish an old
selection after cancellation. There are no additional network requests.

Focused regression checks cover the actual four-sector split in production JS
and the exact Swift day policy (four sectors including positioning, duplicated
cache references, missing supplied selection, cross-date isolation, off days and
non-air activities). A production-root UI check scrolls to all four cards in
Roster and Today; it is included in the bounded startup job alongside the existing
clean-install public-login and cached countdown/navigation checks. CI results
must distinguish simulator setup failures from tests that actually execute.

The user reported improved performance in 2.29.29. No device FPS/hitch trace,
battery measurement or actual locked/Always-On glass appearance is verified here.
The 2.29.29 glass/AOD fallback is retained. Successful account authentication and
session preservation still require the user's authorized device session.

Primary Apple references:
- https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone
- https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays
- https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
