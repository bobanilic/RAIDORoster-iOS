from pathlib import Path
import subprocess
import unittest


class NativeReferenceChecks(unittest.TestCase):
    def test_actual_reference_script_is_read_only_bounded_and_minimizes_data(self):
        root = Path(__file__).resolve().parents[1]
        subprocess.run(['node', str(root / 'tests/native_raido_reference_checks.js'),
                        str(root / 'RAIDORoster-Web2IPA/RAIDORoster/NativeRAIDOTiming.swift')],
                       check=True, capture_output=True, text=True, timeout=30)
