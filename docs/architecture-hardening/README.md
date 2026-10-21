# Controlled architecture hardening

## Baseline and scope

Development base: `eef8c96e81734368fac41d38a320d164926ed5f8`, `codex/today-priorities`, version 2.29.31 / 22931. Remote references were fetched on 21 October 2026; this was still the development head. Work is isolated on `codex/architecture-hardening`, targeting the development branch in PR #12. PR #11 and main are not modified.

Before extraction ContentView.swift contains 10,421 lines / 467,016 bytes. It combines roster value models, timing/formatting helpers, reminders, calendar export, navigation, roster/calendar UI, map rendering, sensor observers, Today briefings, Fleet networking and UI, settings, and theme presentation. RosterStore already owns roster persistence/ingestion and must retain that ownership. AppState already suppresses irrelevant root invalidation. The production build directly compiles committed sources; the historical patch system is retired.

`codex/getjet-fleet-reliability` is already an ancestor of this development head (`git merge-base --is-ancestor` succeeded). There are no outstanding commits on that branch to merge.

## Historical CI evidence

Baseline run: https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39485799946

| Check | Result | Evidence / limits |
| --- | --- | --- |
| Python / command-line checks and Release packaging | Passed | release job 118845763311 |
| Native XCTest | Failed compilation | job 118845763469: local `flight` helper called main-actor `activity` from nonisolated context; no native assertions ran |
| Public mobile login UI | Failed assertion | full simulator artifact: test failed after 98.037 s waiting for public login form, line 38; not proof of an authentication failure |
| Four sectors / two duty groups | Passed | full simulator log: 183.670 s |
| Production startup / tab responsiveness | Interrupted | started, then suite hit the 900 s subprocess deadline; an event-loop-idle notification was not received; no completed result |
| Today return / automatic map / disabled notifications | Not run | suite interrupted before this test |

Full simulator artifact: https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39485799946/artifacts/12295192038 . Console output showed only a tail; the full artifact was inspected to recover the login assertion failure. The native runner also selected only four classes, omitting existing AircraftHTTPTests, FlightPowerTests and FlightRequestSlotTests.

## Validation infrastructure changes

The local Today fixture is explicitly `@MainActor`; production isolation settings and assertions are unchanged. The native runner executes the full test target. Startup CI uses separate matrix jobs for four-sector, public-login, responsiveness and Today-return scenarios, with fail-fast disabled, the existing 900 s command deadline, explicit simulator boot completion, and retained xcresult bundles. A failure in public-site rendering cannot prevent other scenarios executing. This does not classify a timed-out test as a pass or substitute fixtures for real authentication.

Artifact verification additionally examines Mach-O load commands: ARM64 alone is insufficient because an ARM64 simulator binary has the same CPU type. Device platform and absence of code-signature load commands, signature directories and provisioning profiles are checked for the unsigned deliverable. Receipts record checked-out HEAD; CI explicitly checks out the PR head rather than attributing a synthetic merge commit to source.

## Lifecycle / performance audit

Static findings to preserve (not measured speed or battery improvements):

- AppState owns exactly one roster store/browser and publishes only deduplicated availability changes. The root's @StateObject remains the owner across tab navigation.
- RosterStore restores disk state in a detached worker; generation checks prevent a clear/import race resurrecting stale data. Calendar/reminder services remain owned by their existing callers.
- Today keeps its map collapsed initially and defers Apple Maps creation. Minute countdowns update their leaves. Tab activation must not start a new roster import or a second flight service.
- RosterTimestamp caches at most 2,048 parsed stamps with a fixed-format formatter. This existing optimization remains intact.
- Fleet retains a state-owned store, four-request concurrency, refresh deadlines, bounded partial publications, detached cache restoration, source timestamps, cancellation and shared HTTP provider backoff. Its sixty-second refresh loop is gated by active tab and active scene. Absence of ADS-B data does not indicate AOG.
- AircraftHTTPClient retains original cache receipt times and a bounded 4 MiB / 128-entry response cache. The existing URLProtocol tests cover backoff, pacing, cancellation and cache provenance; the runner must actually execute them.

No device is attached to this Linux workspace. Xcode compilation/tests run in GitHub Actions on macOS 15 Intel / Xcode 26.3. Authenticated account login, WebKit session survival on the owner's phone, sensor evidence, Lock Screen appearance, ProMotion frame pacing and duty-length battery consumption require owner-device testing. No FPS, launch-latency or energy savings are inferred from a file split.

## Owner device checklist

1. Install as an update first. Check roster archives, documents, pay profiles, settings and portal session remain present.
2. Use a separate clean installation when ready; open the centered login action, type and submit your own credentials, extract the roster, close/reopen the portal, then relaunch. No credentials belong in logs.
3. Cold launch with network disabled and an existing saved roster; navigate Today → Roster → More → Today repeatedly, change months, scroll and foreground the app.
4. Inspect all four sectors and separate report/release boundaries on a day with two duty envelopes; check positioning, overnight duties, standby M/A/N and hotel-change markers.
5. Open Fleet, inspect an aircraft, leave the tab and background the app. Compare live/stale source labels and confirm absence of data does not imply operational status.
6. Check Live Activities enabled in iOS, each existing glass/frosted/solid preference and fallback, lock/unlock and Dynamic Island countdowns.
7. Compare responsiveness and battery during similar duties, recording device/OS, app version, elapsed time and battery levels. Validate flight detection with actual sensor evidence; route estimates remain distinct from measured fixes.

## Established native baseline

Run https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39621350442 , native job 119295819643: all **75 XCTest cases passed** before production extraction (65.471 s test execution). Release/checks also passed. A separate run at 7171def passed the compiler and 73/75 cases, with two assertions in one simulated login-expiry/retry case failing. The history fixture now becomes key while running, restores the previous key window on cleanup, and includes sanitized worker diagnostics on failure. No authentication assertions were removed. Simulator selection now ranks iPhone generations rather than sorting SE above modern models by name.

## Extraction 1 — roster values and formatting

- `RosterModels.swift`: immutable crew, activity, roster, snapshot/change and metric models, plus their private local helpers. Stored property names, Codable synthesis and IDs are unchanged.
- `RosterFormatting.swift`: shared roster stamp/pickup parsing, display formatting, standby labels, aircraft labels and the existing nil-if-empty helper. Only helpers actually shared with views have module access; model-only helpers stay private.
- `RosterDayPresentation.swift`: same-date envelope aggregation and sector collection, preserving independent duty timing.
- The Xcode application target explicitly includes all three files. Store ownership remains in RosterStore.
- Day checks compile the complete canonical day policy. Timing checks compile the real roster models/formatting instead of string-extracted properties on incomplete model doubles. Existing assertions are retained.
- ContentView after this extraction: **9,860 lines / 445,481 bytes**. A source-statement conservation check passes after ignoring imports, blank lines and the two required shared helper access changes. This is a maintainability change, not a measured runtime speedup.
- Candidate release version becomes **2.29.32 / 22932** in every project configuration, including the widget.
