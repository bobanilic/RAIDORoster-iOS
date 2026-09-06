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
