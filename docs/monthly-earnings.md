# Monthly block hours and earnings — 2.20.0

A compact earnings card appears below the month navigator in both Roster Calendar and List views. It follows the selected month and opens a native monthly breakdown. The amount can be hidden on the roster card. All records remain on the device and work offline; no salary backend, subscription or uploaded contract is required.

## Calculation and editing

- Scheduled block-time estimates use FLIGHT start/end UTC timestamps. POSITIONING, reserve, standby and training do not automatically earn block-hour pay. Actual block duration is entered as H:MM and explicitly confirmed after the sector ends. Elapsed time alone never confirms it. Confirmed duration replaces the scheduled duration, while both totals remain visible.
- Each sector is assigned in full to its UTC departure month; no midnight proration is invented. The selected roster snapshot takes precedence, and other cached snapshots recover boundary sectors. Deduplication uses flight code, route and UTC start. Missing or invalid times are excluded with a visible incomplete-estimate count.
- Source timestamp or aircraft changes invalidate matching saved edits; removed or moved sectors cannot keep contributing pay through orphaned edits. The detail screen reports edits needing review and allows removing unmatched records. No fleet tracking positions or airborne-time estimates determine pay.
- EUR presets from the supplied terms: JCC/CC 25/hour, SCC 31.25/hour, eligible daily compensation 50/day, qualifying instructor line check 35/sector. Rates are user-editable per month. New unsaved months inherit the most recent earlier saved rates; existing saved months retain theirs. Briefing/deputy roles never change pay rates. No personal identifiers or contract PDF are committed.
- An away-trip date editor proposes inclusive UTC dates only for overnight trips. Crew must review eligible operational days, deselect exceptions and confirm. Selected dates are stored as sets and split into their own months, including cross-month trips. Same-day trips do not generate per diems. Roster reserve/rest/hotel days are not automatically presumed payable. This is a manual confirmation workflow, not automatic payroll eligibility determination.
- Additional pay, standby payments, reimbursements and deductions require an amount and description. Reimbursements have a separate breakdown line; all entered amounts contribute to the estimated cash total. No fixed salary, standby rate, tax deduction or currency conversion is invented.
- Money uses integer cents; durations use integer minutes. Hourly pay rounds half-up to cents after aggregating minutes by rate. Company rounding or pay-period rules may differ; rates and records are an estimator, not an authoritative payslip.

## Monthly payment

Current and future months remain changing forecasts. Past months allow recording the amount received and payment date. Expected payment window is the 10th–15th of the following month, as specified by the user. Recording payment saves the comparison estimate. Subsequent roster/rate changes are flagged without rewriting that saved comparison. Received-minus-estimate is displayed; payment records can be corrected or removed with confirmation. Editing the received amount preserves the original comparison estimate.

## Validation

Foundation-only checks cover money parsing/rounding, duration parsing, duplicate and wrong-month sectors, missing times, confirmed versus scheduled hours, future flights, source changes, orphan edits, cross-month per diems, same-day exclusions, adjustments, payment-window rollover, frozen comparisons and persistence/corruption behavior. The macOS workflow also compiles all 63 patches into the complete unsigned iOS app and reruns announcement/fleet tests.

On-device review remains necessary: Calendar and List month navigation; narrow screens and larger text; keyboard entry; hidden card amount; actual-hours edits; a cross-month away trip with excluded days; offline relaunch; payment recording and later rate changes. Roster-derived start/end timestamps need comparison against actual company off/on-block records before treating forecasts as exact payroll hours.

## 2.20.1 daily-payment correction

The user's clarified rule supersedes the manual-only per-diem setup above: one daily payment (EUR50 preset) for flight, standby and positioning days, plus OFF/other days away from home. OFF at home and reserve-only RES days are unpaid. A reserve activated into a real flight/standby/positioning duty is treated as that actual duty, once per day. RES stays excluded even if old trip dates or paid overrides contain it. BLH pay remains additive only for operating flight sectors.

The roster drives a visible day ledger. For non-operating days it estimates location from adjacent route arrivals/departures (up to seven days), with explicit station as fallback. Conflicting or missing location is flagged for review and excluded until corrected. BEG is the initial home-airport preset, editable per month. No September dates or personal roster entries are hardcoded into the app. Calendar/list card and details use the same daily policy. Manual paid dates form a union with automatic dates, never an additional daily charge. Per-date exclusions persist across resyncs; swipe Automatic to clear an override. Optional fields maintain compatibility with 2.20.0 saved records and frozen payment comparisons.

Existing manual `standby` adjustments are retained but excluded from totals when automatic standby days are present, with an explicit review message. This prevents paying standby twice after upgrade. Genuine extra pay can be re-entered under Extra pay; new standard standby adjustments are no longer offered separately.

The regression fixture represents the user's September calendar (synthetic per-sector durations totaling 73:54): 15 flight days, 4 standby, 2 POS, 5 away OFF, 1 away OTHER, and 3 home OFF. Expected result: EUR1847.50 block pay + 27 × EUR50 = **EUR3197.50**. Replacing the OTHER day with RES reduces the expected total to EUR3147.50. Location ambiguity, paid/unpaid overrides, legacy manual-date overlap and standby migration also have checks. These validate the supplied scenario, not an unobserved live roster import on the phone.
