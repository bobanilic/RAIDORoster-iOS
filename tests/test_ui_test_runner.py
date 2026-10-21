import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ui_test_runner', Path(__file__).resolve().parents[1] / 'tools/ui_test_runner.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
AX_FAILURE = 'The test runner failed to initialize for UI testing. Timed out waiting for AX loaded notification'
PASS = "Test Case '-[RAIDOMapChecks.MapGestureUITests testExample]' passed (1.0 seconds)."


class UITestRunnerChecks(unittest.TestCase):
    def exercise(self, outputs, clock=(0, 0, 100, 100)):
        calls = []
        def run(command, stdout, **kwargs):
            index = len(calls); calls.append((command, kwargs['timeout']))
            code, log = outputs[index]; stdout.write(log)
            return subprocess.CompletedProcess(command, code)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(module.subprocess, 'run', side_effect=run), patch.object(module.time, 'monotonic', side_effect=clock):
                module.run_startup_tests(['xcodebuild', '-only-testing:Suite/Class/testExample'], root/'run.log', root/'run.xcresult')
            logs = [path.read_text() for path in sorted(root.glob('run-attempt-*.log'))]
        return calls, logs

    def test_setup_recovery_keeps_results_and_original_total_budget(self):
        calls, logs = self.exercise([(65, AX_FAILURE), (0, PASS)])
        self.assertEqual([call[1] for call in calls], [900, 800])
        self.assertTrue(calls[0][0][-2].endswith('run.xcresult'))
        self.assertTrue(calls[1][0][-2].endswith('run-retry.xcresult'))
        self.assertEqual(logs, [AX_FAILURE, PASS])

    def test_assertion_failure_is_never_retried(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.exercise([(65, "Test Case '-[Suite.Class testExample]' started.\nXCTAssertTrue failed\n" + AX_FAILURE)])

    def test_other_setup_failures_are_not_retried(self):
        with self.assertRaises(subprocess.CalledProcessError): self.exercise([(65, 'Installation failed')])

    def test_zero_or_wrong_tests_cannot_be_reported_as_passed(self):
        for log in ['', PASS.replace('testExample', 'testOther')]:
            with self.subTest(log=log), self.assertRaises(RuntimeError): self.exercise([(0, log)])
