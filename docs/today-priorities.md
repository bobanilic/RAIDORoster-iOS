# Today priorities and historical route previews — 2.29.18

Today has an urgency-sorted priority area and a compact pickup/alcohol strip
above the tab bar. Both use the same minute-aligned timestamp and refresh on
foreground activation. Pickup becomes "Pickup due" at its scheduled time;
the app does not infer that transport occurred. Pre-duty alcohol timing retains
the existing 12-hour rule and pickup/report reference. It does not declare that
drinking is permitted after the pre-duty window.

The feed chooses the newest validated snapshot per month, independently of the
selected calendar month. Future relocations remain visible on OFF days and
across month boundaries. Current-day relocations and imminent pickups are more
prominent than distant arrangements. Date-only relocations have no invented
midnight countdown. Missing hotel, time or transport details are shown for review;
a missing pickup is flagged for duties only when transport is actually mentioned.
Cards identify saved roster information older than 24 hours.

Settings includes relocation reminders (evening before and morning of the move)
and an optional reminder before the alcohol precaution starts. Existing pickup
and report lead-time preferences are preserved. Morning reminders use local wall
time across daylight-saving changes; a known early move gets an earlier alert.
The scheduler uses all authoritative saved upcoming months, replaces superseded
requests and serializes Settings/automatic writes within the existing 60-request
budget. Notifications work offline once scheduled; updated times require a roster
refresh. Tapping a duty reminder opens Today and its current details when present.

Selecting a calendar date shows its scheduled sectors on the bundled offline map.
Multiple duty rows on the same date contribute sectors. Unknown airports do not
produce invented connecting segments. Expanding opens a separate map for pan/zoom;
the compact preview allows normal roster scrolling. Saved GPS points appear only
when an exact session key matches the selected sector. Dashed scheduled routes
and saved GPS are labeled separately; historical previews start no tracking session.

Both themes, all palettes and light/dark/system appearance remain supported.
No new map assets or external map service are required. Hotel lookup opens Maps
only on the user's explicit tap. Automatic history downloading is unchanged and
remains outside this update's scope.

Validation includes native policy/ingestion tests for urgency, overdue pickup,
midnight, DST, OFF-day logistics, cross-month pickups, missing details, deleted
relocations, date-only events and recorded-session matching. The real JavaScript
extractor is exercised with an RLCN HTML fixture. Simulator UI checks cover the
persistent strip, detail sheets, OFF-day relocation, route expansion and the
existing map gestures/palette settings. Synthetic fixtures cannot establish which
details exist in the owner's current GetJet roster.
