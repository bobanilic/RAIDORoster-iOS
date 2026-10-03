# Fleet responsiveness, 2.26.1

The previous refresh loop waited for every aircraft sequentially, including
provider fallbacks, before publishing any positions. Its request timeout was
an idle-data timeout, with no explicit resource deadline. Refresh stayed
disabled throughout that pass. The list also repeatedly flattened the whole
roster, constructed date formatters and scanned up to 720 history observations
per aircraft while computing sections, sorting and drawing rows. Every aircraft
completion and history mutation emitted another screen update.

These are code-level bottlenecks consistent with the reported lag and apparent
stalls. There is no device trace establishing which accounted for each incident.

The new pass runs at most four aircraft jobs, publishes partial observations at
most once per second, and cancels jobs after a 30-second aircraft budget. Provider
requests have a five-second idle and eight-second total resource limit. Optional
route enrichment can take up to eight additional seconds. Public provider
backoff, identity validation and source timestamps remain intact. A cached
observation never becomes fresh just because a new request failed.

The screen owns its polling task. Refresh restarts that task, backgrounding
cancels it, and returning to the foreground starts a new pass. A replacement
waits for the cancelled pass to release its slot; cancelled responses cannot
overwrite a replacement. History publishes in a batch, cache encoding/writes
run on an actor outside the UI, and cache loading/response decoding run off the
main actor. Duplicate cache registrations no longer trap during restoration.

Roster evidence is indexed when the roster changes, with parsed UTC timestamps
and registration lookups. Live intelligence is reused within a 15-second bucket
and invalidated when observations change. Section arrays are evaluated once in
the body instead of repeatedly for counts and rows.

`FleetRefreshChecks.swift` tests concurrency, deadlines, partial delivery,
cancellation, recovery and a 5,000-activity roster. `check_fleet_refresh_store.py`
extracts the actual generated store and tests it with a local URLProtocol fake,
including an immediate restart while cancelled requests unwind. The complete
generated iPhoneOS app must also compile in CI.

Offline Flight Companion estimates the user's current flight along its saved
route after accepting sensor takeoff evidence. This is separate from the public
Fleet feed, which needs internet for new observations. Neither mode supplies a
measured aircraft position without GNSS or fresh ADS-B. Background delivery and
the experimental cabin/motion thresholds still require testing on a real flight.
