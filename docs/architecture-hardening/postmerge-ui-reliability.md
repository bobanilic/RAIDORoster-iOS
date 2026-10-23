# Post-merge simulator follow-up

> Historical chronology with the [final validation and merge](#final-validation-and-merge) recorded below. Intermediate Intel/ARM choices and failed runs are preserved as evidence; the active workflow uses ARM for all simulator jobs and Intel for the device release build.

Base: `649b638b3e82fa424d19a06b53668fe1ef06c3b1` (main, 2.29.32 / 22932).
The merged source tree is identical to the validated `ff8e907` source tree.
No production source, existing test assertion, fixture, version, existing
timeout or retry policy is changed by this follow-up. A later confirmation
identified a separate WebKit readiness race; its test synchronization is
described below.

## Evidence

[Post-merge run 39774227130](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39774227130)
passed release/package verification, native tests, four sectors on Intel and
Today-return on ARM. The two remaining Intel UI jobs failed:

- [Login, job 119811349050](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39774227130/job/119811349050):
  the real public mobile form, password field, keyboard and Reload checks ran.
  The first Done tap synthesized its event at test time 139.71 s; at 200.35 s,
  XCTest reported no app event-loop idle notification. The following TabBar
  snapshot query timed out (line 64). The enclosing 900 s command timed out
  after an observed 913.564 s, including termination overhead. Its xcresult
  remained in Staging with no final Info.plist, so it is not a completed run.
  The bounded diagnostic watcher triggered; even host-side `ps` timed out
  after 5 s, preventing a stack sample. This resembles the earlier Intel
  Today stall, but does not identify its underlying app/framework/host cause.
  Artifact: 12425282359.
- [Responsiveness, job 119811349286](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39774227130/job/119811349286):
  Settings and the Pickup reminder button were reached. The preview tap was
  synthesized at 158.95 s; the first toast existence query began at 161.09 s
  and returned no match at 165.22 s. The production sample lives for 4 s;
  this lookup alone consumed 4.13 s. The toast assertion at line 157 failed;
  dismissal, background/reactivation and the second launch did not execute.
  The test case failed in 191.460 s, xcodebuild exited 65 after 703.294 s,
  and a finalized failed xcresult was retained. Simulator shutdown also
  exceeded its 30 s bound; deletion completed. Artifact: 12425471885.

These outcomes are retained as failures. A passing form or an owner's initial
device check is not proof of account authentication, session persistence,
device responsiveness under every condition, or battery performance.

## Narrow correction

Run login and responsiveness on the same standard `macos-15` ARM host that
passed Today twice before merge and again after merge. Preserve Xcode 26.3,
the simulator profile selection, the two cold launches in responsiveness,
every toast/login assertion and the real public website. Keep the four-sector
scenario on `macos-15-intel`, and keep release/native jobs on Intel, retaining
cross-architecture build/test coverage.

This is a CI environment correction, not a claimed production hang fix.
It avoids extending or freezing the real toast merely to make a test pass,
adding assertion-failure retries, or weakening XCTest idleness semantics.
The existing process-exit and finalized-xcresult summary checks remain the
success criteria. The bounded diagnostic watcher and cleanup remain active.

Run the full workflow on the correction, then, if both affected jobs pass,
repeat each affected job once on a fresh runner. Record their actual process,
result-bundle and cleanup outcomes; do not rerun failures until green.

## Confirmation exposed a separate login readiness race

The first full run at `779683f` passed all six jobs:
[run 39806753306, attempt 1](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39806753306/attempts/1).
Login completed on its first command in 280.928 s; responsiveness completed on
its first command in 718.497 s. Both finalized bundles report one passed test,
zero failed/skipped tests, and neither log has a missing-idle warning. Both
responsiveness launch cycles found and tapped the real toast; lookup times
were 0.23 s and 0.38 s. The earlier Intel recording confirms the toast appeared
and expired normally. No toast duration or app change is warranted.

The single fresh login confirmation, [job 119939600695](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39806753306/job/119939600695),
failed at the existing keyboard assertion (line 57), in 42.950 s. Its command
exited 65 after 306.028 s; the failed result bundle was finalized and retained
as artifact 12441520272. This was neither the earlier Done-transition hang nor
a command timeout. The full-run pass does not supersede this failure.

The recording still shows the native `Opening RAIDO…` indicator and a blank
web viewport while AX has already reported the username/password elements and
the test has tapped the username. The final form paints near the end of the
keyboard wait. The test previously equated DOM/AX existence with readiness.
Hardware keyboard configuration was considered, but the recording does not
establish that as the cause; no simulator preference is changed speculatively.

Before initial interaction, Reload completion and reopening the login, the
test now additionally waits for the existing loading indicator to disappear
and the username field to exist and be hittable. Each readiness gate uses the
same 40 s bound as public-page loading and rejects the native load-error UI.
The original form, password, keyboard (5 s), reload, centering, tab-selection,
reopening and return assertions and actions are retained. No sleep, repeated
tap, authentication mock or assertion-failure retry is introduced. All work
remains within the existing 900 s command deadline.

Apple documents [element existence](https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence(timeout:))
and [hittability](https://developer.apple.com/documentation/xcuiautomation/xcuielement/ishittable)
separately. The native loading indicator supplies the additional navigation
state needed here. The underlying Intel stall remains undiagnosed.

After this test-only synchronization correction, require a new full workflow
and one fresh confirmation of each affected scenario. The failed confirmation
is retained, not retried unchanged or marked as passing. The proposed change
must not merge while a required job remains unsuccessful.

## Intel control failed before UI testing

At `f48c0ac`, [run 39814007425](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39814007425)
passed release verification, all 75 native tests and all three ARM UI scenarios.
Login completed on its first command in 485.935 s; its finalized bundle reports
Passed 1 / Failed 0 / Skipped 0, all three readiness markers, 66.977 s test-case
execution and no missing-idle warnings. Responsiveness completed its first
command in 298.038 s; Today completed in 376.912 s. Their completed result
bundles were verified. The new readiness correction did not remove assertions.

The remaining [four-sector Intel job 119951254017](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39814007425/job/119951254017)
never entered XCTest: simulator `bootstatus` timed out after 360.527 s, then
shutdown and deletion also exceeded their separate 30 s limits (32.693 s and
36.317 s observed). Artifact 12442822453 retains the build and provisioning
logs. This is a failed simulator provisioning job, not a passed four-sector
case, assertion failure, or demonstrated application regression. The overall
workflow is correctly failed. GitHub also reported an Actions degradation
during this run, delaying job-state updates; that does not establish the cause
of this host-local boot failure.

Use `macos-15` ARM for the entire UI matrix, which has now demonstrated a
successful boot and completed test in every other UI scenario. Keep release
and the full native suite on Intel, preserving cross-architecture validation.
The earlier choice to retain four sectors on Intel was a control; this new
boot failure justifies removing that remaining UI-host dependency. Do not
increase its boot limit, skip its assertions, or retry the failed job unchanged.

Require a full green workflow on this configuration before merging. The
automatic post-merge workflow supplies the independent fresh-run confirmation
for all UI scenarios, avoiding separate serialized reruns of the same jobs.
No production files or version/build metadata change.

## Native WebKit fixtures hit the same Intel service failures

At `1e473b4`, [run 39817533573](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39817533573)
passed release verification and all four ARM UI jobs on their first commands:
four sectors 226.452 s, login 354.820 s, responsiveness 296.577 s and Today
367.270 s. All four result bundles finalized and verified, and all four
simulators shut down and deleted successfully. Downloaded four-sector and
login bundles independently confirm Passed 1 / Failed 0 / Skipped 0 and no
missing-idle warnings. Login completed all three readiness gates.

The [native Intel job 119959844986](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39817533573/job/119959844986)
compiled and ran all 75 cases but correctly failed with three assertions across
two WebKit fixture tests. The full log is retained in artifact 12443588913:

- `testActualJavaScriptExtractsSanitizedHTML`: the 60 s script-payload
  expectation was unfulfilled, followed by a nil-payload unwrap failure
  (RosterBridgeTests lines 247–248); case duration 107.962 s.
- `testActualRelocationHTMLReachesUpcomingPriorities`: the 60 s fixture-ready
  expectation was unfulfilled (line 179); case duration 70.931 s.
- At 17:10:08 UTC WebKit reported its networking process took 19.892908 s to
  launch. At 17:11:29 UTC it reported `gpuProcessExited: reason=Unresponsive`.
  These are callback/readiness timeouts, not incorrect parser output. The
  remaining tests continued, including the other WebKit/cache fixtures. The
  full run reports 75 tests / 3 failures in 290.990 s; it is not a green run.

Native tests use CoreSimulator and WebKit too. Move that job to `macos-15` ARM
with the existing dynamic `ARCHS=platform.machine()` setup, unchanged Xcode
26.3, all 75 test selections and existing deadlines. The native source and
assertions are unchanged. The release job remains on Intel and verifies real
ARM64 iPhoneOS app/widget binaries, retaining Intel compiler-host coverage.
The final configuration uses one host architecture for all simulator work.

This is an evidence-based environment correction. It does not establish a
definitive root cause inside Intel WebKit or claim the prior native failures
passed. Require a fresh full workflow, including all 75 native tests on ARM,
before merging, and use the automatic post-merge workflow for independent
confirmation. No parser changes, larger callback timeouts or failure retries
are introduced.


## Final validation and merge

PR [#13](https://github.com/bobanilic/RAIDORoster-iOS/pull/13) merged at
`33c72551d5d8ecd1cbe8dc6364f1924cd7ebdd36` on 22 October 2026.
Its tree equals the tested head `91467eb7014d0260741a4dee08657fead850aa20`.
Both the [pre-merge workflow 39822207285](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39822207285)
and independent [post-merge workflow 39825182354](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39825182354)
passed all six jobs on their first full attempts.

| Post-merge job | Verified result |
| --- | --- |
| Release | Python/Swift checks, app/widget build and unsigned ARM64 iPhoneOS IPA/resource verification passed; version 2.29.32/build 22932 |
| Native XCTest | All 75 tests passed with zero failures; case execution 31.681 s |
| Four sectors | First UI command exited 0 in 272.932 s; finalized result verified |
| Public login | First UI command exited 0 in 315.469 s; finalized result verified |
| Responsiveness | First UI command exited 0 in 267.382 s; finalized result verified |
| Today-return | First UI command exited 0 in 438.714 s; finalized result verified |

All four UI jobs uploaded their result bundles. Each simulator shutdown and
deletion exited 0. These are completed processes and validated result bundles,
not passing assertion messages inside timed-out commands. Earlier failures
remain failures and are not superseded as historical evidence.

The final configuration uses ARM `macos-15` for native and all four UI jobs,
Intel `macos-15-intel` for the device release build, and pinned Xcode 26.3.
Production app/widget code and version were unchanged by PR #13. Every original
UI test line was retained; the public-login test additionally synchronizes on
visible, tappable readiness before interaction.

The exact underlying Intel simulator/service fault and blocked Today stack
remain unconfirmed. The watcher still has a known collection limitation:
its bounded host `ps` lookup timed out during recorded stalls. A future change
should validate stack capture against a deliberately stalled disposable test
app before claiming improved diagnosis. These simulator passes do not establish
account authentication/session persistence or duty-length device battery use.
