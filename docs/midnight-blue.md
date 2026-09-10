# Midnight Blue · 2.20.8

Implements the selected Midnight Blue concept with native SwiftUI components.

- Deep navy canvas (#081725), navy cards (#102437), raised controls (#163149), blue actions and fine blue-gray borders.
- Compact month calendar with category dots, change markers, selected-day details and separate block-hours/earnings cards.
- Today shows the current duty followed by Announcements, Fleet and Crew Control quick actions. The existing detailed briefing remains below.
- Fleet adds registration/type/operator search and card rows showing observation age for every available snapshot, including fresh airborne positions.
- Announcements, earnings, Settings and supporting native sheets share the same surfaces. The eager announcement scroll layout, exact source scripts, favorites and font controls remain intact.
- Midnight is selected once on upgrade; subsequent System/Light/Midnight choices remain persistent. Light mode uses corresponding pale blue surfaces.

The mockup contains illustrative data. Production uses the existing roster, earnings and ADS-B models. The authenticated RAIDO website keeps its own web content and behavior within the themed native shell.

No changes to pay policy, RES exclusion, RAIDO monthly BLH authority, persistence formats, flight tracking inference or announcement wording. The release is produced by the existing patch/build pipeline, with `v2208_midnight.py` applied last.

Validation: regenerate the complete patch sequence, compare functional model/source-data hashes with 2.20.7, and run the existing macOS Swift checks and unsigned iOS build. Visual acceptance remains with the owner on device.

## 2.20.9 interaction corrections

Owner testing found reduced calendar usefulness, unresponsive controls and choppy reading. This revision restores the original detailed day cells (flight numbers, duty labels and secondary times) and the original earnings layout with separate, non-overlapping navigation and privacy controls. Today uses one sheet destination for its three quick actions. Calendar selection recovers when moving between cached months.

The reader now caches prepared paragraphs per language and saves reading position after a 400 ms quiet period, also flushing it when leaving, switching language or backgrounding. This removes paragraph preparation and immediate persistence from scroll-position changes while retaining eager layout, original source text, reading controls and saved positions.

These are code-level fixes for identified issues. The reported device-specific button failures and scrolling need owner confirmation; a successful build is not a substitute for that check.
