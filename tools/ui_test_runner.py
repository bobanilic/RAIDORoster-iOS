"""Bounded UI execution, with one recovery before any test case has started."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import threading
import time


ATTEMPT_BUDGET_SECONDS = 900
RESULT_BUDGET_SECONDS = 60



class UIHangDiagnostics:
    """One host-side stack sample per UI command; never changes its result.

    No app instrumentation, location access or extra XCTest queries are used.
    The watcher reads the existing log and samples only the app belonging to
    this simulator after a marked transition stalls or XCTest reports no idle.
    """
    def __init__(self, command, attempt_log):
        destination = next((value for value in command if 'platform=iOS Simulator,id=' in value), '')
        match = re.search(r'id=([A-Fa-f0-9-]{36})(?:,|$)', destination)
        self.udid = match[1] if match else None
        self.attempt_log = Path(attempt_log)
        self.log_path = self.attempt_log.with_name(self.attempt_log.stem + '-diagnostics.log')
        self.sample_path = self.attempt_log.with_name(self.attempt_log.stem + '-mainthread.log')
        self.case_started = False
        self.pending = None
        self.claimed = False
        self.stop_event = threading.Event()
        self.worker = None

    def observe(self, text, now):
        for line in text.splitlines():
            if re.search(r'Test Case .*started[.:]', line):
                self.case_started = True
            if not self.case_started:
                continue
            marker = re.search(r'RAIDO_UI_TRANSITION (BEGIN|END) (\S+)', line)
            if marker:
                if marker[1] == 'BEGIN':
                    self.pending = (marker[2], now)
                elif self.pending and self.pending[0] == marker[2]:
                    self.pending = None
            if 'App event loop idle notification not received' in line and not self.claimed:
                self.claimed = True
                return 'XCTest did not receive the app event-loop idle notification'
        if self.case_started and self.pending and now - self.pending[1] >= 15 and not self.claimed:
            self.claimed = True
            return 'Transition did not complete within 15 s: ' + self.pending[0]
        return None

    def app_pid(self):
        listing = subprocess.run(['xcrun', 'simctl', 'spawn', self.udid, 'launchctl', 'list'],
                                 check=True, capture_output=True, text=True, timeout=5)
        candidates = []
        for line in listing.stdout.splitlines():
            fields = line.split()
            if (len(fields) == 3 and fields[0].isdigit()
                    and re.match(r'UIKitApplication:com\.bobanilic\.raidoroster(?:\[|$)', fields[2])):
                candidates.append(fields[0])
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one RAIDO app in the selected simulator; found ' + str(len(candidates)))
        pid = candidates[0]
        executable = subprocess.run(['ps', '-ww', '-p', pid, '-o', 'comm='], check=True,
                                    capture_output=True, text=True, timeout=5).stdout.strip()
        if Path(executable).name != 'RAIDORoster':
            raise RuntimeError('Resolved PID is not the RAIDO app; refusing to sample it')
        return pid

    def capture(self, reason):
        with self.log_path.open('a') as output:
            output.write(datetime.now(timezone.utc).isoformat() + ' Capture requested: ' + reason + '\n')
            output.flush()
            try:
                pid = self.app_pid()
                output.write(f'Sampling app PID {pid}, simulator {self.udid}; duration=5s, command bound=20s\n')
                output.flush()
                result = subprocess.run(['sample', pid, '5', '-file', str(self.sample_path)],
                                        stdout=output, stderr=subprocess.STDOUT, timeout=20)
                valid = self.sample_path.is_file() and self.sample_path.stat().st_size > 0
                output.write(f'Sample command exit={result.returncode}; nonempty sample={valid}\n')
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                output.write('Stack capture unavailable: ' + str(error) + '\n')
            output.flush()

    def note(self, message, mode='a'):
        try:
            with self.log_path.open(mode) as output:
                output.write(message + '\n')
            return True
        except OSError as error:
            print('UI diagnostic log unavailable: ' + str(error), flush=True)
            return False

    def start(self):
        if not self.udid or not self.note('UI hang diagnostics armed; max 1 capture; transition threshold 15s.', mode='w'):
            return
        def watch():
            try:
                with self.attempt_log.open(errors='replace') as source:
                    remainder = ''
                    while not self.stop_event.wait(1):
                        data = remainder + source.read()
                        last = data.rfind('\n')
                        complete, remainder = (data[:last + 1], data[last + 1:]) if last >= 0 else ('', data)
                        reason = self.observe(complete, time.monotonic())
                        if reason:
                            self.capture(reason)
                            return
            except Exception as error:
                # Diagnostics must not replace the actual xcodebuild outcome.
                self.note('Diagnostic watcher failed: ' + str(error))
        worker = threading.Thread(target=watch, daemon=True)
        try:
            worker.start()
            self.worker = worker
        except RuntimeError as error:
            self.note('Diagnostic watcher unavailable: ' + str(error))

    def stop(self):
        self.stop_event.set()
        if self.worker:
            # Discovery 5+5 s and sampling 20 s are independently bounded.
            self.worker.join(timeout=35)
            self.note(f'Watcher stopped={not self.worker.is_alive()}; capture requested={self.claimed}')


def uninitialized_accessibility_runner(log):
    return ('The test runner failed to initialize for UI testing' in log
            and 'Timed out waiting for AX loaded notification' in log
            and re.search(r'Test Case .*started[.:]', log) is None)


def verify_result_bundle(result, expected):
    # Xcode writes Info.plist (including the root record) when it finalizes the
    # bundle. Passing case messages in a killed process are not a complete run.
    if not (result / 'Info.plist').is_file():
        raise RuntimeError('UI result bundle was not finalized: ' + str(result))
    summary_log = result.with_suffix('.summary.log')
    with summary_log.open('w') as output:
        subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)],
                       check=True, stdout=output, stderr=subprocess.STDOUT, timeout=RESULT_BUDGET_SECONDS)
    summary = json.loads(summary_log.read_text())
    count = len(expected)
    if (not count or summary.get('result') != 'Passed'
            or summary.get('totalTestCount') != count or summary.get('passedTests') != count
            or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0):
        raise RuntimeError('UI result bundle does not confirm every selected test passed: ' + str(summary_log))
    print('Verified completed UI result bundle: ' + str(result), flush=True)


def run_startup_tests(command, log_path, result_path, budget=ATTEMPT_BUDGET_SECONDS):
    """At most two commands, each bounded by budget; never retry a test failure.

    The initialization-only recovery gets a fresh budget. A slow AX failure
    must not leave a few seconds for the recovered test's result finalization.
    Result inspection has a separate 60 s bound and cannot turn a timeout green.
    """
    log_path, result_path = Path(log_path), Path(result_path)
    expected = {value.rsplit('/', 1)[-1] for value in command if value.startswith('-only-testing:')}
    with log_path.open('w') as combined:
        def event(message):
            line = datetime.now(timezone.utc).isoformat() + ' ' + message
            print(line, flush=True)
            combined.write(line + '\n')
            combined.flush()

        for attempt in range(1, 3):
            result = result_path if attempt == 1 else result_path.with_name(result_path.stem + '-retry.xcresult')
            attempt_log = log_path.with_name(log_path.stem + f'-attempt-{attempt}.log')
            started = time.monotonic()
            event(f'UI runner attempt {attempt} started; budget={budget}s; result={result.name}')
            outcome = 'interrupted'
            diagnostics = UIHangDiagnostics(command, attempt_log)
            with attempt_log.open('w') as output:
                try:
                    diagnostics.start()
                    finished = subprocess.run(command + ['-resultBundlePath', str(result), 'test-without-building'],
                        stdout=output, stderr=subprocess.STDOUT, timeout=budget)
                    outcome = f'exit={finished.returncode}'
                except subprocess.TimeoutExpired:
                    outcome = 'timed out (test messages cannot establish successful process completion)'
                    raise
                finally:
                    output.flush()
                    event(f'UI runner attempt {attempt} ended; {outcome}; elapsed={time.monotonic() - started:.3f}s')
                    diagnostics.stop()
                    combined.write(attempt_log.read_text(errors='replace'))
                    combined.flush()
            log = attempt_log.read_text(errors='replace')
            if finished.returncode == 0:
                completed = set(re.findall(r"Test Case '-\[[^\]]+ (\w+)\]' passed", log))
                if not completed or not expected.issubset(completed):
                    raise RuntimeError('UI command succeeded without verified completion of every selected test: ' + str(sorted(expected - completed)))
                verify_result_bundle(result, expected)
                return
            if attempt == 1 and uninitialized_accessibility_runner(log):
                event('Retrying uninitialized UI accessibility runner once; no test case entered. Original result retained.')
                continue
            raise subprocess.CalledProcessError(finished.returncode, command)
