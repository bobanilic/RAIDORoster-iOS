# Monthly block hours and earnings — 2.20.2

A compact earnings card appears below the month navigator in both Roster Calendar and List views. It follows the selected month and opens a native monthly breakdown. The amount can be hidden on the roster card. All records remain on the device and work offline; no salary backend, subscription or uploaded contract is required.

## Calculation and editing

- Scheduled block-time estimates use FLIGHT start/end UTC timestamps. POSITIONING, reserve, standby and training do not automatically earn block-hour pay. Actual block duration is entered as H:MM and explicitly confirmed after the sector ends. Elapsed time alone never confirms it. Confirmed duration replaces the scheduled duration, while both totals remain visible.
- Each sector is assigned in full to its UTC departure month; no midnight proration is invented. The selected roster snapshot takes precedence, and other cached snapshots recover boundary sectors. Deduplication uses flight code, route and UTC start. Missing or invalid times are excluded with a visible incomplete-estimate count.
- Source timestamp or aircraft changes invalidate matching saved edits; removed or moved sectors cannot keep contributing pay through orphaned edits. The detail screen reports edits needing review and allows removing unmatched records. No fleet tracking positions or airborne-time estimates determine pay.
- EUR presets from the supplied terms: JCC/CC 25/hour, SCC 31.25/hour, eligible daily compensation 50/day, qualifying instructor line check 35/sector. Rates are user-editable per month. New unsaved months inherit the most recent earlier saved rates; existing saved months retain theirs. Briefing/deputy roles never change pay rates. No personal identifiers or contract PDF are committed.
- Additional pay, reimbursements and deductions require an amount and description. Reimbursements have a separate breakdown line. Legacy manual standby entries are suppressed whenever automatic standby daily pay is present so standard standby is not counted twice.
- Money uses integer cents; durations use integer minutes. Hourly pay rounds half-up to cents after aggregating minutes by rate. Company rounding or pay-period rules may differ; rates and records are an estimator, not an authoritative payslip.

## Confirmed daily-payment policy

The app now uses the crew member's confirmed payroll practice rather than assuming every duty earns the EUR50 daily payment:

- **Outside Home Base:** EUR50 daily payment on eligible roster days.
- **FLIGHT outside Home Base:** EUR50 daily payment **plus** BLH pay.
- **FLIGHT at Home Base:** **BLH only**, no EUR50 daily payment.
- **STB / STANDBY:** EUR50 daily payment, including at Home Base; no BLH.
- **POSITIONING / POS:** EUR50 daily payment; no BLH.
- **OFF outside Home Base:** EUR50 daily payment.
- **OFF at Home Base:** unpaid.
- **RES / RESERVE:** unpaid everywhere, even outside Home Base and even if an old manual paid date exists.
- DND, vacation, leave and sickness remain unpaid unless the policy is later explicitly changed.

Home Base defaults to BEG and remains editable per month. For flight days, the strongest automatic evidence is the first origin and last destination of that UTC day. A duty starting and finishing at Home Base is treated as a home-base duty and receives BLH only. A duty that starts or ends away from Home Base is treated as away and receives the daily payment. For OFF/other days the app infers location from nearby arrivals/departures and explicit station data. Ambiguous location is flagged for review instead of being silently paid.

Manual per-date corrections remain available for every non-RES day. RES cannot be manually forced paid. Stored/manual away-trip dates fill gaps when location is genuinely unknown; they no longer override clear home-base flight evidence.

## Contract cross-check

Annex 1 defines JCC/CC at EUR25 per Block Hour, SCC at EUR31.25 per Block Hour, Line Check at EUR35 per sector, and daily compensation at EUR50 calculated according to UTC. It states daily compensation applies to duty trips out of Home Base without returning the same day. The contract also defines Home Base as a location where per diems are normally not provided. The app therefore treats the contract as the baseline and uses the crew member's separately confirmed payroll practice for the two operational exceptions: home-base standby receives EUR50 and positioning receives EUR50.

## Monthly payment

Current and future months remain changing forecasts. Past months allow recording the amount received and payment date. Expected payment window is the 10th–15th of the following month. Recording payment saves the comparison estimate. Subsequent roster/rate changes are flagged without rewriting that saved comparison. Received-minus-estimate is displayed; payment records can be corrected or removed with confirmation. Editing the received amount preserves the original comparison estimate.

## Validation

Foundation-only checks cover money parsing/rounding, duration parsing, duplicate and wrong-month sectors, missing times, confirmed versus scheduled hours, future flights, source changes, orphan edits, persistence/corruption behavior, UTC midnight boundaries, and the confirmed pay matrix above. Explicit regression checks now cover a BEG round-trip flight receiving BLH only, an away flight receiving daily pay + BLH, home-base standby receiving EUR50, positioning receiving EUR50, and away RES remaining unpaid.

The September regression fixture represents 15 flight days, 4 standby, 2 POS, 5 away OFF, 1 away OTHER, and 3 home OFF with synthetic per-sector durations totaling 73:54. Expected result remains EUR1847.50 block pay + 27 × EUR50 = **EUR3197.50**. Replacing one paid day with RES reduces the expected total by exactly EUR50 to **EUR3147.50**.

On-device review remains necessary for Calendar/List layout, keyboard entry, hidden card amount, actual-hours edits, offline relaunch and comparison against an actual payslip. Roster-derived timestamps must still be checked against the company's final block-hour record before treating a forecast as exact payroll.
