import importlib.util
import json
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
SUMMARY = dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)


class UITestRunnerChecks(unittest.TestCase):
    def exercise(self, outputs, summary=None, finalized=True):
        calls = []
        inspections = []
        def run(command, stdout, **kwargs):
            if command[0] == 'xcrun':
                inspections.append(command)
                self.assertTrue(kwargs['check'])
                self.assertEqual(kwargs['timeout'], 60)
                stdout.write(json.dumps(SUMMARY if summary is None else summary))
                return subprocess.CompletedProcess(command, 0)
            index = len(calls); calls.append((command, kwargs['timeout']))
            code, log = outputs[index]; stdout.write(log)
            if isinstance(code, Exception):
                raise code
            if finalized:
                result = Path(command[-2]); result.mkdir(); (result/'Info.plist').touch()
            return subprocess.CompletedProcess(command, code)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # The observed AX failure took ~658 s; retry completion at ~900 s
            # must retain its own finalization allowance rather than 242 s.
            with patch.object(module.subprocess, 'run', side_effect=run), patch.object(module.time, 'monotonic', side_effect=[0, 658, 658, 900]):
                try:
                    module.run_startup_tests(['xcodebuild', '-only-testing:Suite/Class/testExample'], root/'run.log', root/'run.xcresult')
                except Exception:
                    self.assertLessEqual(len(calls), 2)
                    self.assertIn(outputs[-1][1], (root/'run.log').read_text())
                    raise
            logs = [path.read_text() for path in sorted(root.glob('run-attempt-*.log'))]
            self.assertEqual(len(inspections), 1)
            self.assertTrue(list(root.glob('*.summary.log')))
        return calls, logs

    def test_setup_recovery_keeps_results_and_fresh_bounded_budget(self):
        calls, logs = self.exercise([(65, AX_FAILURE), (0, PASS)])
        self.assertEqual([call[1] for call in calls], [900, 900])
        self.assertTrue(calls[0][0][-2].endswith('run.xcresult'))
        self.assertTrue(calls[1][0][-2].endswith('run-retry.xcresult'))
        self.assertEqual(logs, [AX_FAILURE, PASS])

    def test_assertion_failure_is_never_retried(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.exercise([(65, "Test Case '-[Suite.Class testExample]' started.\nXCTAssertTrue failed\n" + AX_FAILURE)])

    def test_other_setup_failures_are_not_retried(self):
        with self.assertRaises(subprocess.CalledProcessError): self.exercise([(65, 'Installation failed')])

    def test_second_initialization_failure_is_not_retried(self):
        with self.assertRaises(subprocess.CalledProcessError): self.exercise([(65, AX_FAILURE), (65, AX_FAILURE)])

    def test_zero_or_wrong_tests_cannot_be_reported_as_passed(self):
        for log in ['', PASS.replace('testExample', 'testOther')]:
            with self.subTest(log=log), self.assertRaises(RuntimeError): self.exercise([(0, log)])

    def test_passing_messages_do_not_override_process_timeout_or_failure(self):
        for code in [65, subprocess.TimeoutExpired('xcodebuild', 900)]:
            with self.subTest(code=code), self.assertRaises((subprocess.CalledProcessError, subprocess.TimeoutExpired)):
                self.exercise([(code, PASS)])

    def test_unfinalized_bundle_is_not_a_pass(self):
        with self.assertRaisesRegex(RuntimeError, 'not finalized'): self.exercise([(0, PASS)], finalized=False)

    def test_incomplete_failed_skipped_or_wrong_count_bundle_is_not_a_pass(self):
        for changed in [dict(result='Failed'), dict(result='Unknown'), dict(passedTests=0),
                        dict(totalTestCount=0), dict(totalTestCount=2), dict(failedTests=1), dict(skippedTests=1)]:
            with self.subTest(changed=changed), self.assertRaisesRegex(RuntimeError, 'does not confirm'):
                self.exercise([(0, PASS)], summary=SUMMARY | changed)

    def test_unreadable_result_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory)/'run.xcresult'; result.mkdir(); (result/'Info.plist').touch()
            with patch.object(module.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'xcresulttool')):
                with self.assertRaises(subprocess.CalledProcessError): module.verify_result_bundle(result, {'testExample'})
            with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired('xcresulttool', 60)):
                with self.assertRaises(subprocess.TimeoutExpired): module.verify_result_bundle(result, {'testExample'})


class UIHangDiagnosticChecks(unittest.TestCase):
    UDID = '7D0F1BB7-39B3-41B5-AF87-732C7FAA5D45'
    START = "Test Case '-[Suite.Class testToday]' started.\n"

    def observer(self, root):
        return module.UIHangDiagnostics(['xcodebuild', '-destination', 'platform=iOS Simulator,id=' + self.UDID], root/'attempt.log')

    def test_ax_initialization_before_case_does_not_trigger_sampling(self):
        with tempfile.TemporaryDirectory() as d:
            observer = self.observer(Path(d))
            self.assertIsNone(observer.observe(AX_FAILURE, 0))
            self.assertIsNone(observer.observe('App event loop idle notification not received', 100))
            self.assertFalse(observer.claimed)

    def test_healthy_transition_does_not_trigger_sampling(self):
        with tempfile.TemporaryDirectory() as d:
            observer = self.observer(Path(d))
            self.assertIsNone(observer.observe(self.START + 'RAIDO_UI_TRANSITION BEGIN cycle-0-more\n', 0))
            self.assertIsNone(observer.observe('RAIDO_UI_TRANSITION END cycle-0-more\n', 2))
            self.assertIsNone(observer.observe('', 100))
            self.assertFalse(observer.claimed)

    def test_stalled_transition_claims_exactly_one_capture(self):
        with tempfile.TemporaryDirectory() as d:
            observer = self.observer(Path(d))
            observer.observe(self.START + 'RAIDO_UI_TRANSITION BEGIN cycle-0-more\n', 0)
            self.assertIsNone(observer.observe('', 14.9))
            self.assertIn('cycle-0-more', observer.observe('', 15))
            self.assertIsNone(observer.observe('App event loop idle notification not received', 60))
            self.assertIsNone(observer.observe('', 900))

    def test_idle_failure_after_test_entry_claims_capture_without_markers(self):
        with tempfile.TemporaryDirectory() as d:
            observer = self.observer(Path(d)); observer.observe(self.START, 0)
            self.assertIn('idle notification', observer.observe('App event loop idle notification not received', 60))

    def test_wrong_transition_end_cannot_cancel_pending_capture(self):
        with tempfile.TemporaryDirectory() as d:
            observer = self.observer(Path(d))
            observer.observe(self.START + 'RAIDO_UI_TRANSITION BEGIN restored-more\n', 0)
            observer.observe('RAIDO_UI_TRANSITION END cycle-0-more\n', 2)
            self.assertIn('restored-more', observer.observe('', 15))

    def test_process_discovery_is_scoped_and_does_not_sample_the_runner(self):
        listing = ('PID Status Label\n'
                   '10 0 UIKitApplication:other.app[ABC]\n'
                   '20 0 UIKitApplication:com.bobanilic.raidoroster.mapchecks.xctrunner[DEF]\n'
                   '32148 0 UIKitApplication:com.bobanilic.raidoroster[GHI]\n')
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); observer=self.observer(root); calls=[]
            def run(command, **kwargs):
                calls.append((command, kwargs['timeout']))
                if command[0]=='xcrun': return subprocess.CompletedProcess(command, 0, listing)
                if command[0]=='ps': return subprocess.CompletedProcess(command, 0, '/simulator/RAIDORoster.app/RAIDORoster\n')
                self.assertEqual(command[:3], ['sample', '32148', '5'])
                Path(command[-1]).write_text('Main thread stack: fixture')
                return subprocess.CompletedProcess(command, 0)
            with patch.object(module.subprocess, 'run', side_effect=run): observer.capture('Fixture transition timeout')
            self.assertEqual([c[1] for c in calls], [5, 5, 20])
            self.assertEqual(calls[0][0][3], self.UDID)
            self.assertIn('nonempty sample=True', observer.log_path.read_text())

    def test_ambiguous_or_missing_app_pid_refuses_to_sample(self):
        for listing in ['', '1 0 UIKitApplication:com.bobanilic.raidoroster[A]\n2 0 UIKitApplication:com.bobanilic.raidoroster[B]\n']:
            with self.subTest(listing=listing), tempfile.TemporaryDirectory() as d:
                observer=self.observer(Path(d))
                with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess('list',0,listing)) as run:
                    observer.capture('Fixture')
                self.assertEqual(run.call_count, 1)
                self.assertIn('Stack capture unavailable',observer.log_path.read_text())
                self.assertFalse(observer.sample_path.exists())

    def test_pid_reuse_or_wrong_executable_refuses_to_sample(self):
        with tempfile.TemporaryDirectory() as d:
            observer=self.observer(Path(d))
            responses=[subprocess.CompletedProcess('list',0,'123 0 UIKitApplication:com.bobanilic.raidoroster[A]\n'),
                       subprocess.CompletedProcess('ps',0,'/other/TestRunner\n')]
            with patch.object(module.subprocess, 'run',side_effect=responses) as run:observer.capture('Fixture')
            self.assertEqual(run.call_count,2)
            self.assertIn('refusing to sample',observer.log_path.read_text())

    def test_sample_timeout_is_retained_and_does_not_propagate(self):
        with tempfile.TemporaryDirectory() as d:
            observer=self.observer(Path(d))
            with patch.object(observer,'app_pid',return_value='123'), patch.object(module.subprocess,'run',side_effect=subprocess.TimeoutExpired('sample',20)):
                observer.capture('Fixture')
            self.assertIn('Stack capture unavailable',observer.log_path.read_text())

    def test_failed_or_empty_sample_is_never_labeled_successful(self):
        with tempfile.TemporaryDirectory() as d:
            observer=self.observer(Path(d))
            with patch.object(observer,'app_pid',return_value='123'), patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess('sample',1)):
                observer.capture('Fixture')
            self.assertIn('exit=1; nonempty sample=False',observer.log_path.read_text())

    def test_log_watcher_captures_live_idle_failure_once_and_stops(self):
        import threading
        with tempfile.TemporaryDirectory() as d:
            observer=self.observer(Path(d))
            observer.attempt_log.write_text(self.START+'App event loop idle notification not received\n')
            captured=threading.Event()
            with patch.object(observer,'capture',side_effect=lambda reason: captured.set()) as capture:
                observer.start()
                try:self.assertTrue(captured.wait(timeout=3),'Live watcher did not consume the attempt log')
                finally:observer.stop()
                self.assertEqual(capture.call_count,1)
            self.assertIn('Watcher stopped=True; capture requested=True',observer.log_path.read_text())
