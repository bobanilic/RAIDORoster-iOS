#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "${1:-all}" in
  checks)
    python3 -m unittest discover -s tests -p 'test_*.py' -v
    bash tools/run_generated_checks.sh
    ;;
  build)
    bash RAIDORoster-Web2IPA/build-unsigned-ipa.sh
    python3 tools/verify_raido_artifacts.py
    ;;
  native-tests)
    python3 tools/run_native_tests.py
    ;;
  preview)
    python3 tools/preview_ice_tabs.py --palette-only
    # Stop simulator services before runner orphan-process cleanup.
    xcrun simctl shutdown all || true
    ;;
  all)
    bash "$0" checks
    bash "$0" build
    ;;
  *) echo "Usage: $0 [checks|build|native-tests|preview|all]" >&2; exit 2 ;;
esac
