# Today transition investigation

The initial `b5b1a85` workflow's Today-return job [119562340959](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39698066688/job/119562340959) failed after a synthesized More tap. The app stopped servicing main-run-loop requests; XCTest could not evaluate the selected-tab snapshot. This was an entered test failure (xcodebuild exit 65 after 734.420 s), not the 900 s command deadline. The later unchanged [diagnostic rerun](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39698066688/job/119575388188) passed, including finalized result verification and simulator deletion. The original failed bundles remain evidence of an unresolved intermittent stall.

There is no captured stack identifying the cause. XCTest's remote spindump request returned “not supported.” The gesture-gate warning occurred after delayed main-thread callbacks resumed; it does not establish that gesture starvation caused or cleared the stall. A predicate wait for selection would still evaluate the element, and cannot directly remove the idle wait already occurring inside the tap. No production fix is claimed from an unchanged passing rerun.

## Bounded diagnostic change

The test now prints begin/end markers around More and subsequent Today selection, including restored-cache navigation. All existing selected-state, scroll, map, countdown, details and cache assertions remain. It still fails immediately after an assertion failure. The test supports three to six transition cycles (minimum three); CI requests six through `TEST_RUNNER_RAIDO_UI_TRANSITION_CYCLES` (xcodebuild strips the prefix for the test runner). The test logs its effective count so forwarding is verified in the artifact. This exercises the sequence more thoroughly. This is additional navigation coverage, not a test retry.

A host-side watcher reads the existing xcodebuild log once per second. It requests at most one stack sample per command when a marked transition has not ended after 15 s, or XCTest reports a missing event-loop idle notification after a test has entered. It never sends accessibility queries or changes the app. Pre-test AX failures do not trigger sampling.

Process lookup uses the host's process list, accepts only the full installed `RAIDORoster.app/RAIDORoster` executable path inside the selected simulator UDID's application container and a single running PID, then rechecks that path for the selected PID. Missing, ambiguous, reused/wrong or test-runner PIDs are rejected. There is no broad process-name fallback. Lookup commands have separate 5 s limits. The macOS `sample` command requests a five-second capture with a 20 s command bound. The worker has a bounded join. Tool/permission/discovery errors are retained as diagnostic failures; they cannot convert a failed UI command into success or replace its exit status.

The existing artifact glob retains `*-diagnostics.log` and any `*-mainthread.log` sample. On a healthy transition, no process sample is taken. Logging and the watcher run only in test tooling, with synthetic fixture data. Production app sources, observable ownership, timers, map/tracking policies, persisted data, version and signing are unchanged. Existing 900 s per-command and 50 minute outer bounds and the single pre-test AX recovery remain.

## Decision after the diagnostic run

- If the stall recurs, inspect the main-thread/worker stacks and correlate them with transition markers before choosing a production or infrastructure correction.
- If the run passes without a captured stall, report a passing stronger regression scenario, not an established root cause or proven stall fix.
- If collection is unavailable, report the exact discovery/tool failure; do not classify the original stall as infrastructure-only.
- Do not suppress quiescence, remove assertions, use passing log messages to override process failure, increase retries or merge either PR.

## Separate native fixture race

The `c305f3c` [native job](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39707090684/job/119589565872) compiled and executed all 75 cases, but `testMobileEntryAndRecoveryStates` failed its two watchdog-state assertions. The same fixture passed on `7e16314`. It slept for 100 ms instead of synchronizing with the main-actor watchdog's published failure. Under load, the test's continuation can run before that watchdog has completed; a nominal 20 ms sleep is not a scheduling guarantee.

The fixture now subscribes to the actual non-nil error publication before starting navigation and awaits that expectation with a five-second bound. The original loading/error assertions remain. Cancellation uses an inverted publication expectation over 200 ms, retaining the original nil-error assertion and detecting transient errors during that window. This changes only test synchronization, with no production watchdog or timeout changes. Native compilation/execution must still pass in Xcode; local Python checks do not establish that result. This is independent of the unresolved Today UI stall.

## First-run four-sector interruption

The `7e16314` [four-sector job](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39706690031/job/119591085941) entered its test, then failed the Roster count-existence assertion while a location-permission alert was still onscreen. Its command exited 65 after 703.791 s; this was not a command timeout or a passing test. The default interruption handler attempted to tap “Don’t Allow” twice but did not establish dismissal.

Four-sector startup now explicitly uses the existing Today fixture's expected-location-prompt handling before native navigation. That handling is shared without removing its prompt-identity or button assertions, and now additionally requires the alert to disappear within five seconds. All four codes, sector-count and independent-duty assertions in Roster and Today remain. A persistent prompt is still a failure, with no test retry. This makes the precondition explicit; simulator execution must verify the correction.

## Instrumented recurrence and diagnostic repair

The `7e16314` [Today job](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39706690031/job/119591085802) reproduced the stall. Its first command failed AX initialization before any case (538.209 s). Recovery entered the case at 02:08:03.995 UTC on 22 October 2026, tapped More at t=104.51 s and stopped receiving idle replies after synthesized input at t=106.05 s. No end marker or passing case was recorded. The second command hit its 900 s deadline (904.896 s observed including process termination); simulator shutdown and deletion also hit their 30 s bounds, and outer cleanup hit its one-minute limit. These are failed/incomplete results.

The watcher correctly requested a capture at 02:10:05.195 UTC, 15 s after observing the More begin marker. Its `simctl spawn ... launchctl list` lookup itself timed out after five seconds, so no stack was collected. This proves a limitation of that collection path, not whether app code or simulator services caused the stall. Discovery now uses bounded host `ps` commands with strict device-path matching and PID revalidation, without simulator IPC or a broad process-name fallback. A missing/ambiguous/wrong-device executable remains an unavailable diagnostic. All pass/fail rules and retry bounds are unchanged. A new macOS run must verify collection; no production stall fix is claimed.
