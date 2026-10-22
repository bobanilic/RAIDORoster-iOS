# Post-merge simulator follow-up

Base: `649b638b3e82fa424d19a06b53668fe1ef06c3b1` (main, 2.29.32 / 22932).
The merged source tree is identical to the validated `ff8e907` source tree.
No production source, test assertion, fixture, version, timeout or retry policy
is changed by this follow-up.

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
