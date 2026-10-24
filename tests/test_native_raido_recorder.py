"""Execute the actual opt-in recorder against synthetic XHR/fetch clients."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeRecorderChecks(unittest.TestCase):
    def test_recorder_preserves_portal_requests_and_enforces_boundaries(self):
        result = subprocess.run([
            'node', str(ROOT / 'tests/native_raido_recorder_checks.js'),
            str(ROOT / 'RAIDORoster-Web2IPA/RAIDORoster/NativeRAIDORecorder.js'),
        ], text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('behavior checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
