# Automatic offline roster history

After signing in to Live RAIDO, return to the native Roster tab and leave the
app open online. The status beneath Calendar/List shows the month being saved.
There is no need to visit each month manually. Saving pauses in the background
and while Live RAIDO is open, and resumes on return. The queue survives relaunch.

## Downloading months

One private, hosted WKWebView shares the existing portal login. It first requests
the exact month as authenticated HTML and uses the production roster extractor.
If RAIDO supplies a JavaScript shell or ignores query parameters, it loads the
rendered page and operates that page's own selectors, links or Previous/Next
controls, verifying each resulting month. Portal controls preserve form state
and run the portal's own postback/AJAX handlers. The visible portal is not navigated.
No API endpoint or form field is invented.

Year labels and links discover all offered months without the former 120-month
truncation. Initially, a year of history and two upcoming months are queued.
Enabled Previous controls and links found in downloaded pages extend the queue
into older history. Unpublished holes do not establish the beginning of employment.
Requested native calendar months are prioritized online. Records unavailable on
RAIDO cannot be reconstructed.

## Recovery and validation

Native origin, schema, size, date and field checks remain in place. The heading
must match the request, and a dated row must belong to it; legitimate cross-month
hotel/duty context is retained. Rendered pages must be quiet and stable across
two polls. Only explicit empty-state UI establishes an empty month; blank/loading
pages cannot. Empty states never erase a good archive. Sparse archives are accepted
only for an explicitly requested month; live extraction retains its coverage check.

An archive is acknowledged only after protected storage succeeds. The protected,
backup-excluded journal records targets, classified failures, attempts and retry
times. Authentication expiry pauses the batch. Other failures use bounded backoff
with jitter, at most three automatic attempts. Server Retry-After survives even
an explicit Retry. The progress row offers Retry when needed; long-press it for
Copy history diagnostics, containing month keys and failure categories without
employee identifiers, URLs or activities. Current/upcoming snapshots refresh after
six hours; verified history after seven days. Legacy archives are revalidated once.
Clearing cache invalidates in-flight imports and removes the journal.

Historical imports preserve native month selection and change-review state.
Current-month refreshes report genuine changes. Requests are serial with a
one-second gap, bounded timeouts, and no background task. WebKit is released
when saving finishes or pauses.

## Tests and device check

Native XCTest fixtures run the production worker and extractor in WKWebView:
direct HTML, JavaScript rendering, ignored query parameters, Previous controls,
opaque selector values, expired login, durable retries, server throttling,
wrong-month rows, archive write failure and cache invalidation. Synthetic fixtures
do not prove compatibility with every authenticated GetJet portal page.

On the owner's device: sign in, return to Roster, wait for the saved-month count
to increase, then relaunch in airplane mode and check July and earlier. If saving
pauses, copy history diagnostics from the progress row.
