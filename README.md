# RAIDO Roster for iOS

A native companion for the GetJet RAIDO crew portal: offline roster and pickup details, Flight Companion, Fleet status, aircraft-specific announcements, earnings and Pay Profiles, and an encrypted Crew Documents vault. Today and Roster support Ice and GetJet themes, light/dark/system appearance, and coordinated colour palettes.

## Build

Open `RAIDORoster-Web2IPA/RAIDORoster.xcodeproj` in Xcode. The committed Swift, JavaScript, asset catalogue and project are the real app source; no patch generation is needed. Privacy descriptions and background-location configuration are in `RAIDORoster/Info.plist` and apply to Debug and Release.

The deployment target is iOS 17. Both configured CI runners pin Xcode 26.3. GitHub Actions builds the device release on `macos-15-intel` and runs native XCTest and simulator UI jobs on ARM `macos-15`. On a supported Mac with Xcode 26.3:

```sh
bash tools/ci.sh all
```

This runs Python and executable Swift policy/integration checks, builds the unsigned device app and verifies the IPA against the project version, privacy configuration and committed resources. The output is `RAIDORoster-Web2IPA/RAIDORoster-unsigned.ipa`. Despite its name, `all` does not run native XCTest or startup UI scenarios; GitHub Actions runs those in separate jobs.

| Command | Validation |
| --- | --- |
| `bash tools/ci.sh checks` | Python and executable Swift policy/integration checks |
| `bash tools/ci.sh build` | Device release build, unsigned packaging and artifact verification |
| `bash tools/ci.sh native-tests` | Full native XCTest target |
| `bash tools/ci.sh startup --startup-case four-sectors` | Four sectors across two duty groups in Roster and Today |
| `bash tools/ci.sh startup --startup-case login` | Public mobile login interaction and return to native tabs |
| `bash tools/ci.sh startup --startup-case responsiveness` | Production startup, navigation and reminder preview |
| `bash tools/ci.sh startup --startup-case today-return` | Cached Today navigation, deferred map and countdown updates |
| `bash tools/ci.sh preview` | Synthetic palette previews and map checks |

UI scenarios use disposable simulator fixtures. Public login interaction does not establish successful account authentication or session persistence on a phone.

GitHub Actions runs all six validation jobs for every pull request, including documentation-only PRs, so required checks cannot remain pending because of a PR path filter. Pushes to `main` run validation when they touch the application, tools, tests or workflows. Artifacts include the IPA, version/build/commit/hash verification receipt and simulator evidence; IPA artifacts expire after 14 days and test evidence after 7 days. The optional Codemagic runner calls the same scripts. Neither runner commits receipts to the repository. See [repository maintenance](docs/repository-maintenance.md) for branch cleanup, required-check considerations and durable release handling.

## Install

The IPA is unsigned. Sign it with your chosen sideloading setup before installing; provisioning and expiry depend on that setup. For a normal Xcode install, select your development team and device. Open Live RAIDO and sign in to refresh the native cache. Existing cached data and preferences are retained across an update with the same bundle identifier.

## Architecture

- `ContentView.swift`: application navigation, native roster/Today views, maps, settings and Flight Companion integration. It is being split incrementally.
- `RosterModels.swift`, `RosterFormatting.swift` and `RosterDayPresentation.swift`: roster values, shared formatting and same-day duty-envelope aggregation. `RosterStore.swift` owns ingestion, persistence, month archives and change tracking.
- `FleetModels.swift`, `FleetLiveStore.swift` and `FleetView.swift`: aircraft/observation values, Fleet refresh/cache ownership and Fleet presentation.
- `RosterWebView.swift` and `RosterEnhancements.js`: authenticated portal, extraction and calendar-feed bridge.
- Separate policy/model files: flight sensor evidence, Fleet fusion/refresh, map presentation, appearance, announcements, earnings and Pay Profiles.
- `CrewDocumentVault.swift` and related services/views: encrypted document storage and access.
- `AircraftHTTPClient.swift`: shared provider pacing, cooldowns and timestamp-preserving response caching.
- `tests/`: native XCTest, executable Swift checks, Python regressions and simulator UI checks. `tools/check_*.py` checks include compiled integration programs that exercise app logic; native XCTest adds per-test results.
- `tests/fixtures/legacy-earnings.json`: the frozen 64-scenario pre-Pay-Profile reference. `source-2298-manifest.json` records the source-capture provenance.

## What leaves the device

Live RAIDO loads the crew portal through your authenticated WebKit session. Aircraft registrations are sent to configured ADS-B providers for Fleet/Flight Companion lookups; aircraft photos and weather use their external services. Portal requests use your signed-in account and the portal's own access controls. Native roster/cache data, pay edits and document contents are stored locally. Calendar export writes to calendars you authorize, whose subsequent syncing depends on your calendar account. Contact actions open the communication app you choose.

The offline map and bundled announcements require no map-tile service. Offline aircraft positions are estimates when measured signals are unavailable; a saved route alone is not a measured position. Automatic tracking requires its existing arming and evidence gates. Real-flight sensor thresholds still require device evidence.

See `docs/` for feature notes and [the source migration record](docs/source-build.md). Older version-specific notes describe historical implementations; the current build entry point is `tools/ci.sh`.

Native XCTest coverage for roster ingestion, bridge validation and the actual web extractor can be run from the shared `RAIDORosterTests` scheme in Xcode, or with `bash tools/ci.sh native-tests` on macOS. Portal fixtures contain synthetic duties only.

The native test target exercises `RosterStore` independently using a temporary cache directory and disabled calendar/notification side effects. Fleet presentation has its own file; much of the roster/Today presentation remains in `ContentView.swift`.
