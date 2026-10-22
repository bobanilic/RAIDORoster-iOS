# RAIDO 2.29.31: pre-duty precaution lifecycle

The previous event list expired a precaution at pickup/report, then selected the
next future event. That could expose a later envelope of the same roster day or
a following day's precaution during an active flight. Each item also scheduled
notifications independently, bypassing the day-level display selection.

One shared policy now keeps the earliest pickup/report per roster day and uses
the first report through the final release across all same-day envelopes as the
occupied period. Later sectors never create another pre-duty alcohol panel.
An overlapping previous duty, including overnight duty, defers the next event's
availability until release. If duty ends outside the next twelve-hour window,
the panel waits for that window normally. The nominal cutoff still uses twelve
elapsed hours before confirmed pre-duty pickup, or report when pickup is absent.
No cache migration, GPS, polling, countdown timer or new network work is added.
This controls presentation only; company duty/alcohol restrictions still apply.

Today and readiness views, active/pre-alert notifications and native scheduled
Live Activity starts consume the same prepared events. Availability is computed
once in the existing snapshot/date-range/timezone cache. Native ActivityKit
starts are bounded by the prior release; expired Dynamic Island content no
longer says precaution active. When a delayed pre-alert and active alert coincide,
only one notification is scheduled. Existing old schedules reconcile on opening
the updated app. Pickup/report reminders and roster duty envelopes stay separate.

Focused checks cover the reported four-sector/two-envelope day, in-flight and
ground-gap suppression, report/release boundaries, overnight duty, overlapping
roster data, long rest, delayed notification and Live Activity starts. A native
store regression uses actual cached roster ingestion. Existing pickup, countdown,
DST, cache and login checks remain. The known four-sector UI test selector/theme
mismatch is corrected by using GetJet, the theme its identifiers target; assertions
are retained. Device behaviour and final CI results must be reported separately.
