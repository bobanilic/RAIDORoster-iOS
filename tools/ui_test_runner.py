"""Bounded UI execution, with one recovery before any test case has started."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time


ATTEMPT_BUDGET_SECONDS = 900
RESULT_BUDGET_SECONDS = 60


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
            with attempt_log.open('w') as output:
                try:
                    finished = subprocess.run(command + ['-resultBundlePath', str(result), 'test-without-building'],
                        stdout=output, stderr=subprocess.STDOUT, timeout=budget)
                    outcome = f'exit={finished.returncode}'
                except subprocess.TimeoutExpired:
                    outcome = 'timed out (test messages cannot establish successful process completion)'
                    raise
                finally:
                    output.flush()
                    event(f'UI runner attempt {attempt} ended; {outcome}; elapsed={time.monotonic() - started:.3f}s')
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
