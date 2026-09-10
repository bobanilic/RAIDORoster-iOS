# Earnings Pay Profile

RAIDO 2.22.0 moves contract-dependent salary rules into **Settings → Earnings → Pay Profile**.

The profile is effective-dated. Saving a profile for a new `YYYY-MM` month creates a new revision; calculations for earlier months keep the profile that was effective at that time. If no Pay Profile has ever been saved, the app derives a legacy-compatible profile from the existing monthly earnings rates and home airport so current calculations do not change during migration.

## Configurable components

- Profile name and rank label (`JCC`, `CC`, `SCC`, `Custom`)
- Default block-hour role
- Home-base airport
- ISO currency code
- Optional monthly basic salary
- JCC/CC and SCC block-hour rates
- Instructor line-check rate
- Daily allowance amount
- Optional flight-duty-day supplement
- Daily allowance eligibility for home-base flights, away flights, standby, positioning, OFF/other days away, reserve, and DND/leave/sickness

Compensation components stack independently. For example, an away flight day may earn block-hour pay + daily allowance + duty-day supplement, plus an optional monthly basic salary.

## Migration safety

The built-in legacy profile preserves the prior GetJet-oriented defaults:

- Basic salary disabled
- JCC/CC BLH rate from existing monthly rates
- SCC BLH rate from existing monthly rates
- Daily allowance from the existing per-diem rate
- Home-base flight: BLH only
- Away flight: daily allowance + BLH
- Standby: daily allowance
- Positioning: daily allowance
- OFF away: daily allowance
- Reserve: unpaid
- DND/leave/sickness: unpaid
- Duty-day supplement disabled

The dedicated Pay Profile regression check verifies these defaults before each review build.

## Today navigation

Documents no longer lives as a Settings feature. Today keeps the two primary operational shortcuts visible and places **Documents** and **Fleet** under **More (…)** to reduce visual clutter. The Documents vault itself is unchanged.

The current visible operational shortcut remains **Announcements** because the repository does not contain a verified external Web Manuals target. A Web Manuals shortcut should only replace it once the correct deep link or URL is known; the app should not label Announcements as Manuals or open the wrong service.
