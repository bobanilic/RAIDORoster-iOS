# Post-merge simulator follow-up

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
