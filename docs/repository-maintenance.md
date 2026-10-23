# Repository maintenance

## Source and validation baseline

Audit date: 23 October 2026. Default branch: `main`, at
`33c72551d5d8ecd1cbe8dc6364f1924cd7ebdd36`. PRs #1 through #13 are merged.
The [latest application-source workflow](https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/39825182354)
passed release verification, all 75 native tests and all four UI scenarios.
The application remains version 2.29.32/build 22932. Housekeeping changes documentation, PR validation triggers and repository settings; it does not change application behavior.

## Merged branch cleanup inventory

All 17 branch tips below were checked against the full, non-shallow Git history.
Each tip is an ancestor of the baseline main commit: there are zero commits
reachable from that tip but not from main. Removing these refs preserves their
commits through main. On 23 October the 17 refs below and the subsequently merged
`codex/repository-housekeeping` ref were deleted after a fresh ancestry/tip check
against main `2eb1ab72aacfa52c126e4f8ffd5e817808de97a8`. Their commits remain in
main. For future cleanup, fetch again and retain any branch with new work. Never
delete main or force-update another branch.

| Branch | Audited tip |
| --- | --- |
| `codex/architecture-hardening` | `ff8e907f3e1a880db34bc23407fba51f805ec9be` |
| `codex/away-stay-earnings` | `9c6e1c029455b0e0c910d3ea32dcac330cb360b6` |
| `codex/getjet-fleet-reliability` | `b32a62c220dc208f7d1de6d8ec27168dcee1a58b` |
| `codex/network-resilience` | `929b1a97f155d19c44c3c6116a625d637dce9bcc` |
| `codex/offline-history-recovery` | `768e5900756fb8cde7a050f9ddc11147980e134b` |
| `codex/offline-month-cache` | `6844a9318f9e2b49edbe78dcf5dc4298c56b6e9b` |
| `codex/portal-hardening` | `a8af036e4c04261e595b4a52e73940df6e41a404` |
| `codex/protected-state` | `4f1ac4d07360cc7aa11c18d34ac4388649c71782` |
| `codex/roster-domain` | `f8dec7d8f2c3d56b0e0d358c4af85577af5d428c` |
| `codex/source-foundation` | `767784325c6f9cd2e5f460baa55fe19623385847` |
| `codex/today-priorities` | `eef8c96e81734368fac41d38a320d164926ed5f8` |
| `codex/tracking-power` | `74c8c1d87f368e9ef04f910cb393412e4b7806f8` |
| `codex/ui-validation-reliability` | `91467eb7014d0260741a4dee08657fead850aa20` |
| `codex/vector-ice` | `11e8efaaf1b1441ff8a768526e1e103a28b7bcf8` |
| `crew-companion-v215` | `e9608d58517eb14fc3d89320646be5705e313b23` |
| `dev/quality-improvements` | `d461af6b5effb1c7b7671eecb70cf4e307405ab4` |
| `fleet-v1` | `1dd35e4a69018a800eb7257dd633f36c6ffdf8d5` |

Start each future feature or experiment from current main rather than reusing
these historical branches. Delete a new work branch after its PR is merged.
Retain historical commits, test evidence and the source-migration provenance.

## Repository settings to apply through an administrator

At the audit, GitHub reported automatic merged-branch deletion disabled and
main unprotected. The available GitHub connector has file/PR write operations,
but no branch deletion, repository-administration or release-publication tools.
Automatic head-branch deletion was enabled through the authenticated GitHub UI
on 23 October 2026. Main protection is configured through that UI; the protection/trigger PR records
its final verification. The intended rule is:

- Require changes to main through pull requests and block force-pushes and main deletion.
- Require release, native-tests, simulator (four-sectors), simulator (login),
  simulator (responsiveness) and simulator (today-return) checks. Preserve all assertion/result checks.

The workflow now runs its unchanged six jobs for every pull request, including
Markdown-only changes. This deliberately trades additional simulator cost for a
simple, enforceable required-check policy without an untested conditional bypass.
The main-push path filter is retained. Commands, assertions, bounded recovery,
runner/toolchain choices, timeouts and artifact handling are unchanged.
Do not use an existing commit's green checks as results for changed app source.

## Durable unsigned releases

At the audit there were no GitHub Releases. Workflow IPA artifacts expire after
14 days; simulator/native artifacts expire after 7 days. A durable release must
retain the actual verified IPA and its matching verification receipt/checksum.
Before publishing:

1. Download the release artifact from a successful workflow at the exact source commit.
2. Run `tools/verify_raido_artifacts.py --help` and use its supported verification
   options against the matching checkout and actual IPA; inspect the receipt.
3. Confirm app/widget versions, ARM64 iPhoneOS platform, bundled source resources
   and unsigned status. Compute SHA-256 from the actual IPA bytes.
4. Record version/build, exact source SHA, workflow URL, checksum, widget inclusion
   and unsigned/sideloading status in the release. Use an immutable tag pointing
   to that source commit. Never attribute an older IPA to a newer source SHA.

Publishing is a separate action from this documentation change. Do not change
version numbers or rebuild an identical app merely for branch/documentation cleanup.

## Remaining application maintenance

The resolved CI validation issue does not mean all architectural work is complete.
Separate follow-ups are airport/timezone source consolidation (preserving missing
fallback coverage and startup behavior), shared route parsing, validated stall
capture, fleet membership provenance and small ContentView extractions. None is
implemented by repository housekeeping. Avoid speculative provider changes or
production behavior changes in a documentation cleanup.
