# Native offline month archive

The native calendar requests an exact year/month. It no longer clicks the
visible portal's Previous/Next controls, which could load the wrong month when
the native calendar and Live RAIDO were showing different dates.

After a successful roster sign-in, a separate WebKit cache worker uses the same
existing login. It saves detailed HTML snapshots using the actual roster
extractor, including crew, pickup information and the month's authoritative
BLH. It does not execute scripts from fetched month HTML or move the visible
Live RAIDO page. Native origin, schema, size and field checks remain in place;
the returned month's header must match the requested month before import.

Month/year controls and roster links supply available month candidates. If
those controls are absent, the preceding 12 months, current month and next two
months are attempted. At most 120 candidates are handled per batch, with current/past months
prioritized before future months. Older months are also fetched on demand from the
native calendar while online. A successfully saved month remains usable after
relaunch without selecting it in Live RAIDO. Data never downloaded, or no
longer offered by the server, cannot be reconstructed while offline.

Requests run serially, with a one-second gap and a ten-second fetch timeout.
The worker stops when the app leaves the foreground or connectivity/sign-in
fails. It resumes on foreground activation; completed history is skipped,
unpublished months have a six-hour retry delay, and current/future snapshots
are refreshed after six hours. Clearing the cache invalidates pending imports.
The remembered roster URL is stored in a protected, backup-excluded file.

Imports preserve the selected native month. Historical imports leave the
change-review state untouched; current-month refreshes still report changed duties.
Partial published months with fewer than five dated rows are accepted only on
this explicitly requested archive path; empty or wrong-month pages are refused.
Live extraction keeps its existing minimum coverage requirement.

Automated tests cover exact URLs/year rollover, sparse archive validation,
selection preservation, cache retention, offline reload and source persistence.
An actual WebKit fixture exercises fetched HTML with the real extractor and
checks that fetched scripts do not run and the visible month stays unchanged.
Authenticated server month coverage and a cold-start offline check require a
device test with the owner's login.
