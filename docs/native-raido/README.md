# Native RAIDO experiment

Status: milestone 1 transport-comparison prototype with sanitized schema copy (v2);
opt-in, no native imports into the saved roster. Owner reported matching native
and portal JSON for October 2026 on build 22932 (24 October 2026). The screenshot
establishes that comparison result, not decoded roster parity or a wire schema.

Created 24 October 2026 from `main` at
`5fa24ca8b6ba46635770b99275ac8cb31b9874fa`.

## Objective and working approach

Evaluate six improvements in sequence: native roster import, shared session
handling, optional legality enrichment, validated duty catalogs, portal revision
management, and Live Activity delivery. The first deliverable is a read-only
native import prototype. A useful experiment must demonstrate correct data and
an operational benefit before replacing an existing path.

Use `codex/native-raido-experiment` for the experiment and its evidence. Keep
milestones in separate commits. Promote validated work through focused pull
requests against then-current main; avoid making all six milestones a single
merge requirement. Later milestones remain conditional on the evidence and
their own exit criteria. Refresh the baseline when main changes.

The initial planning commit changed no application behavior. The first
implementation adds the explicitly activated diagnostic described below.
No native importer, production endpoint configuration, new backend, signing
change, or application version bump is enabled by this prototype.

### First implementation: capture and native transport comparison

Open Settings → Diagnostics → Native RAIDO experiment. Activate capture,
open Live RAIDO and refresh the roster, then return to compare if a supported
request was observed. Stop capture explicitly or background the app to clear
the captured state. The recorder is never installed during ordinary use.

The experiment observes one same-origin main-frame POST to an actual
`GetRoster` URL, with exactly `month`, `year`, and `hrId` parameters. It keeps
the request in memory and retains a digest of the JSON response. The native
comparison reuses cookies scoped to that URL, refuses redirects, checks for a
changed cookie set, bounds response size, and compares canonical JSON digests.
No raw roster content or credentials are written to a file, clipboard, or report.
No result is passed to RosterStore, Calendar, reminders, or Live Activities.

Build 22933 adds **Copy sanitized schema** and a preview on this screen. Capture
again, compare natively, copy the schema, and paste it into the project chat.
The copy includes the app version, comparison outcome, reviewed property names,
JSON types, and fixed string-format labels. It excludes response scalar values,
request details, endpoint URLs, cookies, account identifiers, and response hashes.
The original v1 export merged unrecognized/dynamic property names under
`<redacted-key>`. The owner's first copied schema exposed excessive merging;
build 22934 replaces that behavior as described below. Mixed arrays merge all
observed element shapes; supported JSON
encoded inside common response-envelope strings is inspected structurally too.
Empty arrays reveal no item shape, and masked names cannot establish exact field
mapping. Any encoded-envelope inspection limit is marked `truncated`.

Only the sanitized schema is retained alongside the existing contract/digests.
Stop, navigation, background, and session-change invalidation clear it. Copy is
an explicit user action to a local-only clipboard item expiring after 15 minutes;
the copied text survives switching apps. Ordinary diagnostics remain unchanged.
Schema processing is bounded by 4 MiB input, depth 20, 100,000 visits, 512 schema
nodes, 16 encoded JSON envelopes, and 64 KiB output. An unsupported schema does
not disable the independent native comparison. Synthetic tests cover value/key
redaction, array merging, encoded envelopes, bounds, and capture/copy/clear.

Build 22934 emits `raido-response-schema-v2`. Unknown sibling fields receive
distinct, scoped `<field-N>` identities that stay consistent across records
within that schema node. A homogeneous dictionary of numeric, date, or UUID
keys instead merges under `<numeric-key>`, `<date-key>`, or `<uuid-key>`. Key
values and unreviewed names remain excluded. These categories describe key
syntax only; they do not prove that numeric keys represent day numbers.
Additional reviewed property names cover validity boundaries, note collections,
text colors, and nested detail values. Their presence in a future capture still
needs observation; static names alone do not prove a wire contract.

Timing fields also emit bounded `timingStringShapes`: digits become `#`, letter
runs become `A`, and unapproved characters become `?`. Delimiters remain to
distinguish timestamp layouts without emitting example dates, times, or words.
At most eight timing shapes are retained per field; excess variants are marked.
Three additional fixtures check anonymous field separation, dictionary key
categories, and value-free timing shapes. This improves schema evidence only;
it does not implement or enable a native roster importer.

The owner's build-22933 export reported another matched native comparison and
described `d` as an object containing `Date`, `HrId`, `Username`, and `Roster`.
`Roster.Days` was an object/dictionary; its merged day shape included
`Details.ActivityDetails` and `Notes` arrays. Activity details included `Activity`,
`Dep`, `Arr`, `STD`, `STA`, nullable `CheckIn`, `CheckOut`, and nested detail/crew
records. Null observations of `ATA`, `ATD`, or `State` do not establish their
complete supported types. The exact day-key format, masked fields, timing
semantics, and operational parity remain unverified.

A portal page using only HTML will not produce this request. An absent capture
is not a native-API failure. A digest match validates this transport/response
comparison only: it does not establish a decoded roster contract, operational
field parity, current-user verification, or that the payload is a usable roster.
Changing server fields or a new revision may produce a legitimate mismatch.
The prototype deliberately does not synthesize an unobserved service URL.

Synthetic tests exercise the real recorder and native boundaries. They do not
establish live decoding compatibility; the owner's reported comparison is a
separate, single-session transport observation. The next milestone-1 work is a verified
wire-schema fixture, canonical-model decoder, and full importer parity checks.

## Evidence boundary

Static inspection of Roster Helper 1.3.4/build 41 established a native
`GetRoster` operation, request construction with `month`, `year`, and `hrId`,
POST/JSON/AJAX headers, and a `URLSession` call. It also identified
`GetCurrentUserInfo`, `GetDailyLegalityValues`, and
`GetMonthlyAccumulatedValues`, session/cookie models, revision components,
versioned catalogs, and ActivityKit push-token/backend support.

These observations do not establish the complete URL construction, current
wire schemas, authorized operation behavior, exact retry policies, or measured
performance. They are not a documented public API contract. Implement our own
client and models; do not add the competitor's binaries, recovered code,
assets, or policy commentary to this repository.

The existing production paths to preserve are:

- `RosterWebView.swift` and `RosterEnhancements.js`: authenticated portal and
  extraction bridge.
- `PortalBridgePolicy.swift`: native origin, bounds, schema, and date checks.
- `RosterMonthCache.swift`: serial foreground work, deadlines, cancellation,
  generation checks, and bounded month requests.
- `RosterStore.swift`: canonical ingestion, month archives, local changes,
  and asynchronous startup restoration.
- `ProtectedJSONFile.swift`: protected atomic persistence and migration.
- `LockScreenActivityController.swift`: local ActivityKit reconciliation,
  preview handling, and scheduled starts on supported OS versions.

## Milestone 1 — read-only native roster import

State: transport-comparison prototype implemented; importer/decoder not started.
Depends on confirming the real service URL and wire payload using the owner's
existing authorized portal session.

1. Reuse successful WebKit authentication; obtain only the portal cookies needed
   for this tenant and verify the current account/HR identity. Do not initially
   add username/password submission or background automatic login.
2. Verify the complete native service URL, required headers, request parameter
   types, and response envelope before selecting production configuration.
   Static operation names alone are insufficient.
3. Independently implement an injected, cancellable native transport with
   explicit timeouts and typed authentication, transport, rate-limit, format,
   unpublished-month, and storage outcomes. Constrain origin, redirects, and
   tenant/account identity.
4. Decode to the existing roster domain model. Preserve source duty codes,
   notes, UTC/local meaning, multiple duty envelopes, and source/freshness
   information. Apply existing validation or equivalent native validation.
5. Expose the prototype only through an explicit experimental control; the
   default path remains the current importer. A comparison run must not commit
   a second snapshot or repeat calendar/reminder side effects.
6. Compare both importers against the same captured roster revision, retaining
   last-known-good data after rejected or incomplete responses. Report sanitized
   differences; account changes or a revision during capture make a run
   inconclusive rather than an importer defect.

Exit criteria: agreement on operational fields across representative months
and all synthetic boundary cases; no wrong-account/wrong-month/partial-data
overwrite; cancellation and session expiry behave correctly; owner-device
validation is recorded. Measure request count, import latency, main-thread
stalls, and peak memory on the same device before claiming an improvement.

## Milestone 2 — centralized session lifecycle

State: not started. Minimal cookie reuse needed by milestone 1 is part of that
prototype; this milestone hardens the shared lifecycle.

Introduce one session owner for browser/native callers, explicit session and
reauthentication states, single-flight refresh, account-generation checks,
tenant isolation, and controlled cookie invalidation. Preserve cookie scope,
expiry, Secure/HttpOnly semantics, and safe storage accessibility. Never log
cookie values, tokens, passwords, or full authenticated request URLs.

Keep interactive Microsoft SSO as the reauthentication route. If automatic
credential login is later justified, add a shared attempt gate that stops on
credential rejection, lockout, or password expiry and honors server cooldowns.
Do not classify those outcomes as ordinary network failures.

Exit criteria: concurrent refresh, expiry during import, logout/account switch,
cancelled work, bad credentials, lockout, and stale completion tests; successful
owner-device sign-in and relaunch/session recovery. Existing public-login UI
tests are not evidence of successful authenticated operation.

## Milestone 3 — optional legality and monthly totals

State: not started. Depends on milestones 1/2 and verified response contracts.

Load the basic roster first. Request legality/totals as separate cancellable
enrichment, with bounded per-session concurrency, backoff for queue limits, and
an explicit per-day/field distinction between server-confirmed values, derived
values, unavailable values, and stale values. Prevent responses for another
account/month/generation from being merged.

Exit criteria: missing records, HTTP 500/queue-limit responses, timeout,
malformed responses, cancellation, and out-of-order completion preserve the
usable roster. No failure becomes a zero or a compliance pass. Verify totals,
units, dates, and timezone meaning against the portal before showing them.

## Milestone 4 — validated duty-code catalog

State: not started. Can be developed independently once baseline fixtures exist.

Centralize our GetJet classification rules in a small, versioned catalog with
schema validation, unique priorities, bounded matching, and visible unknown
codes. Keep raw portal codes and independent display semantics. Preserve
standby M/A/N, positioning, reserve, days off, hotel markers, and multi-sector
duty grouping. Derive operational policy values from authoritative operator
documents, not another application's comments.

Start with bundled rules; remote rule delivery is a separate decision.

Exit criteria: no unexplained change to the existing classification corpus;
ambiguous/header tokens cannot become duties; malformed catalogs fail safely;
unknown codes retain source information. Review deliberate behavior changes
separately from moving existing rules.

## Milestone 5 — portal revision workflow

State: not started. Depends on verified authenticated revision responses.

Add separate read-only availability and old/new revision models. Preserve a
timestamped comparison snapshot, distinguish unavailable/unknown/none/pending,
and invalidate warmed results when account or revision identity changes.
Keep our local snapshot review distinct from airline acknowledgement.

Only add server confirmation after the read-only path is verified. Confirmation
must follow a specific user action and a fresh revision identity check. A
timeout after submission is an uncertain outcome requiring reconciliation,
not a reason to blindly submit again.

Exit criteria: added/removed/modified duties, overnight timing, multiple
envelopes, changed notes, stale revision state, and expired sessions are handled.
Neither background refresh nor local review can acknowledge a portal revision.
Demonstrate the confirmation behavior on-device before enabling it for use.

## Milestone 6 — Live Activity delivery assessment

State: not started. Begin by measuring current local/scheduled behavior.

Verify actual starts, updates, dismissal, stale data, and system-disabled states
with the current code on the owner's installation. Reproduce the glass issue
separately; the competitor's linked styling APIs do not explain its cause.

If remote delivery solves a demonstrated gap, design a separate APNs service,
minimal duty-plan payload, push-token rotation/invalidation, authentication,
and failure behavior. Verify the actual signing/provisioning and widget
installation supports those capabilities. A third-party IPA's entitlement
declaration does not grant them to a sideloaded build.

Exit criteria: a documented local-versus-remote decision, device evidence,
compatible provisioning, explicit data-flow documentation, and delivery/failure
tests. Do not deploy a backend or upload crew schedules merely to finish this
milestone. Background refresh is opportunistic and cannot promise exact times.

## Validation, promotion, and rollback

Use independently authored synthetic fixtures in the public repository.
Authenticated captures remain private; sanitize identities, crew contacts,
rosters, cookies, and tokens before constructing regression fixtures.
Mocked tests establish client behavior, not live service compatibility.

For changed application source, run the checks relevant to the milestone and
all required repository validation at its exact commit: `release`,
`native-tests`, and simulator `four-sectors`, `login`, `responsiveness`, and
`today-return`. Use `tools/ci.sh` and existing runners/assertions. Do not weaken
tests, reuse another commit's green checks, or call unexecuted checks passed.
Documentation-only planning does not establish app functionality.

After each milestone, record scope, exact commit, test results, private-device
evidence summary, known limitations, and rollback mechanism. Keep experimental
behavior opt-in until its exit criteria are met. Keep cache formats compatible
or supply a verified migration. Promote useful milestones independently.

## Immediate next deliverable

A verified request/response contract and fixture-backed, read-only native
import prototype using the existing authenticated session. If live contract
evidence is unavailable, finish transport/parser test seams and identify the
missing evidence explicitly; do not guess a working endpoint or claim a
successful import.
