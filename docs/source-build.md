# Direct-source migration

The shipping 2.29.8 source was captured by replaying all 105 legacy patches on macOS 15 Intel with Xcode 16.4. Capture run: https://github.com/bobanilic/RAIDORoster-iOS/actions/runs/37871806553. The application source corresponds to tested head `b32a62c220dc208f7d1de6d8ec27168dcee1a58b`.

All captured Swift and JavaScript matched the previously reconstructed source byte for byte. The original generated asset catalogue, project and 64 pre-profile earnings results were captured before retiring the generators. `tests/fixtures/source-2298-manifest.json` retains their SHA-256 hashes. The legacy patches remain available in Git history.

The migrated project builds committed source directly. Intentional follow-on differences in this foundation PR are project privacy/background configuration, Debug compilation flags, reading the Settings version from the built bundle, and removal of whitespace on blank lines. No tracking, parser, appearance or earnings logic changes are included.

`tools/ci.sh` is the shared runner entry point. GitHub release and simulator jobs run separately so simulator startup/cleanup cannot consume the release build's time budget. Versioned artifact names and verification receipts read the project version; no runner writes bot receipts into `main`.

The real Info.plist is used in Debug and Release. Packaging never edits the built plist. Verification checks exact privacy strings, background mode, device platform, ARM64 executable and bundled data against source.

The earnings parity check compares current output to the immutable JSON captured from the pre-profile engine. Keep that reference independent of current calculations; do not regenerate it merely to make a failing test pass.
