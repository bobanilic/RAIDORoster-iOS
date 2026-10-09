# RAIDO Roster for iOS

A native companion for the GetJet RAIDO crew portal: offline roster and pickup details, Flight Companion, Fleet status, aircraft-specific announcements, earnings and Pay Profiles, and an encrypted Crew Documents vault. Today and Roster support Ice and GetJet themes, light/dark/system appearance, and coordinated colour palettes.

## Build

Open `RAIDORoster-Web2IPA/RAIDORoster.xcodeproj` in Xcode. The committed Swift, JavaScript, asset catalogue and project are the real app source; no patch generation is needed. Privacy descriptions and background-location configuration are in `RAIDORoster/Info.plist` and apply to Debug and Release.

The deployment target is iOS 17. CI pins Xcode 16.4 to preserve the validated SDK and appearance. On macOS:

```sh
bash tools/ci.sh all
```

This runs Python and native policy/integration checks, builds the unsigned device app and verifies the IPA against the project version, privacy configuration and committed resources. The output is `RAIDORoster-Web2IPA/RAIDORoster-unsigned.ipa`. `tools/ci.sh checks`, `build` and `preview` run the individual stages. Simulator previews use synthetic data.

GitHub Actions validates pull requests and pushes to `main`. Artifacts include the IPA, version/build/commit/hash verification receipt and simulator evidence. The optional Codemagic runner calls the same script. Neither runner commits receipts to the repository.

## Install

The IPA is unsigned. Sign it with your chosen sideloading setup before installing; provisioning and expiry depend on that setup. For a normal Xcode install, select your development team and device. Open Live RAIDO and sign in to refresh the native cache. Existing cached data and preferences are retained across an update with the same bundle identifier.

## Architecture

- `ContentView.swift`: roster models/store, navigation, native roster/Today views, Fleet and Flight Companion integration. It is being split incrementally.
- `RosterWebView.swift` and `RosterEnhancements.js`: authenticated portal, extraction and calendar-feed bridge.
- Separate policy/model files: flight sensor evidence, Fleet fusion/refresh, map presentation, appearance, announcements, earnings and Pay Profiles.
- `CrewDocumentVault.swift` and related services/views: encrypted document storage and access.
- `tests/`: executable Swift checks, Python regressions and simulator UI checks. `tools/check_*.py` compile and exercise actual app logic, rather than only searching source text.
- `tests/fixtures/legacy-earnings.json`: the frozen 64-scenario pre-Pay-Profile reference. `source-2298-manifest.json` records the source-capture provenance.

## What leaves the device

Live RAIDO loads the crew portal through your authenticated WebKit session. Aircraft registrations are sent to configured ADS-B providers for Fleet/Flight Companion lookups; aircraft photos and weather use their external services. Portal requests use your signed-in account and the portal's own access controls. Native roster/cache data, pay edits and document contents are stored locally. Calendar export writes to calendars you authorize, whose subsequent syncing depends on your calendar account. Contact actions open the communication app you choose.

The offline map and bundled announcements require no map-tile service. Offline aircraft positions are estimates when measured signals are unavailable; a saved route alone is not a measured position. Automatic tracking requires its existing arming and evidence gates. Real-flight sensor thresholds still require device evidence.

See `docs/` for feature notes and [the source migration record](docs/source-build.md). Older version-specific notes describe historical implementations; the current build entry point is `tools/ci.sh`.

Native XCTest coverage for roster ingestion, bridge validation and the actual web extractor can be run from the shared `RAIDORosterTests` scheme in Xcode, or with `bash tools/ci.sh native-tests` on macOS. Portal fixtures contain synthetic duties only.
