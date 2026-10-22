# Today transition investigation

The initial `b5b1a85` workflow's Today-return job [119562340959](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39698066688/job/119562340959) failed after a synthesized More tap. The app stopped servicing main-run-loop requests; XCTest could not evaluate the selected-tab snapshot. This was an entered test failure (xcodebuild exit 65 after 734.420 s), not the 900 s command deadline. The later unchanged [diagnostic rerun](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39698066688/job/119575388188) passed, including finalized result verification and simulator deletion. The original failed bundles remain evidence of an unresolved intermittent stall.

There is no captured stack identifying the cause. XCTest's remote spindump request returned “not supported.” The gesture-gate warning occurred after delayed main-thread callbacks resumed; it does not establish that gesture starvation caused or cleared the stall. A predicate wait for selection would still evaluate the element, and cannot directly remove the idle wait already occurring inside the tap. No production fix is claimed from an unchanged passing rerun.

## Bounded diagnostic change

The test now prints begin/end markers around More and subsequent Today selection, including restored-cache navigation. All existing selected-state, scroll, map, countdown, details and cache assertions remain. It still fails immediately after an assertion failure. The test supports three to six transition cycles (minimum three); CI requests six to exercise the sequence more thoroughly. This is additional navigation coverage, not a test retry.

A host-side watcher reads the existing xcodebuild log once per second. It requests at most one stack sample per command when a marked transition has not ended after 15 s, or XCTest reports a missing event-loop idle notification after a test has entered. It never sends accessibility queries or changes the app. Pre-test AX failures do not trigger sampling.

Process lookup is scoped to the selected simulator's `launchctl list`, accepts only the exact application bundle label and a single running PID, then checks the executable name. Missing, ambiguous, reused/wrong or test-runner PIDs are rejected. There is no broad process-name fallback. Lookup commands have separate 5 s limits. The macOS `sample` command requests a five-second capture with a 20 s command bound. The worker has a bounded join. Tool/permission/discovery errors are retained as diagnostic failures; they cannot convert a failed UI command into success or replace its exit status.

The existing artifact glob retains `*-diagnostics.log` and any `*-mainthread.log` sample. On a healthy transition, no process sample is taken. Logging and the watcher run only in test tooling, with synthetic fixture data. Production app sources, observable ownership, timers, map/tracking policies, persisted data, version and signing are unchanged. Existing 900 s per-command and 50 minute outer bounds and the single pre-test AX recovery remain.

## Decision after the diagnostic run

- If the stall recurs, inspect the main-thread/worker stacks and correlate them with transition markers before choosing a production or infrastructure correction.
- If the run passes without a captured stall, report a passing stronger regression scenario, not an established root cause or proven stall fix.
- If collection is unavailable, report the exact discovery/tool failure; do not classify the original stall as infrastructure-only.
- Do not suppress quiescence, remove assertions, use passing log messages to override process failure, increase retries or merge either PR.
