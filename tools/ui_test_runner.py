"""One bounded recovery for a UI runner that never entered a test case."""
from pathlib import Path
import re
import subprocess
import time


def uninitialized_accessibility_runner(log):
    return ('The test runner failed to initialize for UI testing' in log
            and 'Timed out waiting for AX loaded notification' in log
            and re.search(r'Test Case .*started[.:]', log) is None)


def run_startup_tests(command, log_path, result_path, budget=900):
    deadline = time.monotonic() + budget
    log_path, result_path = Path(log_path), Path(result_path)
    with log_path.open('w') as combined:
        for attempt in range(1, 3):
            result = result_path if attempt == 1 else result_path.with_name(result_path.stem + '-retry.xcresult')
            attempt_log = log_path.with_name(log_path.stem + f'-attempt-{attempt}.log')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, budget)
            with attempt_log.open('w') as output:
                try:
                    finished = subprocess.run(command + ['-resultBundlePath', str(result), 'test-without-building'],
                        stdout=output, stderr=subprocess.STDOUT, timeout=remaining)
                finally:
                    output.flush()
                    combined.write(f'\nUI runner attempt {attempt}; result: {result.name}\n')
                    combined.write(attempt_log.read_text(errors='replace'))
                    combined.flush()
            if finished.returncode == 0:
                completed = set(re.findall(r"Test Case '-\[[^\]]+ (\w+)\]' passed", attempt_log.read_text(errors='replace')))
                expected = {value.rsplit('/', 1)[-1] for value in command if value.startswith('-only-testing:')}
                if not completed or not expected.issubset(completed):
                    raise RuntimeError('UI command succeeded without verified completion of every selected test: ' + str(sorted(expected - completed)))
                return
            if attempt == 1 and uninitialized_accessibility_runner(attempt_log.read_text(errors='replace')) and time.monotonic() < deadline:
                print('Retrying uninitialized UI accessibility runner once; no test case entered. Original result retained.', flush=True)
                continue
            raise subprocess.CalledProcessError(finished.returncode, command)
