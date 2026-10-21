"""Compile all committed XTests before booting an available iPhone simulator."""
from pathlib import Path
import json
import platform
import subprocess
import sys
import time
from simulator_devices import newest_iphone

root = Path(__file__).resolve().parents[1]
result = root / 'RAIDORoster-Web2IPA/build/NativeTests.xcresult'
if result.exists():
    raise SystemExit(f'Result bundle already exists: {result}; use a clean CI checkout or move it before rerunning')
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
runtime, device = newest_iphone(devices)
result.parent.mkdir(parents=True, exist_ok=True)
deadline = time.monotonic() + 30 * 60


def stage(name, command, limit):
    path = Path('/tmp/raido-native-' + name + '.log')
    print('Native ' + name, flush=True)
    try:
        with path.open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                           timeout=max(1, min(limit, deadline - time.monotonic())))
    finally:
        print('\n'.join(path.read_text(errors='replace').splitlines()[-100:]), flush=True)


common = ['xcodebuild', '-project', str(root / 'RAIDORoster-Web2IPA/RAIDORoster.xcodeproj'),
          '-scheme', 'RAIDORosterTests', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
          '-derivedDataPath', str(root / 'RAIDORoster-Web2IPA/build/NativeDerivedData'),
          '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=NO',
          'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES',
          'ONLY_ACTIVE_ARCH=YES', 'ARCHS=' + platform.machine()]
try:
    # A boot failure must not hide the native fixture compiler result. Avoid
    # competing simulator migration and compiler work on the Intel CI runner.
    stage('build', common + ['-destination', 'generic/platform=iOS Simulator', 'build-for-testing'], 20 * 60)
    print(f"Testing all native cases in {device['name']} ({runtime})", flush=True)
    if device['state'] != 'Booted':
        stage('boot', ['xcrun', 'simctl', 'boot', device['udid']], 60)
    stage('bootstatus', ['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], 240)
    stage('tests', common + ['-destination', f"platform=iOS Simulator,id={device['udid']}",
                            '-resultBundlePath', str(result), 'test-without-building'], 30 * 60)
finally:
    try:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], check=False, timeout=30)
    except subprocess.TimeoutExpired:
        print('Simulator shutdown timed out; runner cleanup will finish it', file=sys.stderr)
