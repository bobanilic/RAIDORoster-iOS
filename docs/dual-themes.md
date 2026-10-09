# RAIDO 2.29 — Ice and GetJet

More → Settings → Appearance separates Theme (Ice / GetJet) from Mode
(System / Light / Dark). Each theme remembers its own mode. Existing Ice
appearance preferences migrate once without resetting subsequent choices.
GetJet initially follows System; Ice remains the default theme.

GetJet uses warm ivory and green-charcoal surfaces, teal flight labels and
restrained orange selection/alert accents. Its month calendar has open gutters
with short, rounded separators. Its flight sectors use airport/time cards with
per-sector crew access. Ice keeps its existing calendar and agenda layout.
The saved map header and destination clock use the selected palette in either
mode. Actual roster data, briefings, documents and Flight Companion are retained.

Theme changes invalidate presentation through the SwiftUI environment and update
existing UIKit chrome. The app root keeps its identity, preserving authentication,
selected dates and tracking models. Both designs use native type/SF Symbols and
the same map, airport and aircraft resources: no additional photos, font files
or geography bundles are shipped.

Validation applies the complete patch chain from baseline, reapplies this patch
to check idempotence, checks migration and all six theme/mode combinations, then
compiles the iPhoneOS IPA. The disposable simulator host renders all four tabs,
expanded maps and Settings for both themes in Light and Dark, plus System under
both simulator appearances. Synthetic fixtures never enter the release IPA.
The packaged artifact report records compressed and unpacked sizes for comparison
against the prior 2.28 IPA.
