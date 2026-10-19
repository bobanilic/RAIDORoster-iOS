"""Run the committed XCTest target on an available iPhone simulator."""
from pathlib import Path
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
result = root / 'RAIDORoster-Web2IPA/build/NativeTests.xcresult'
if result.exists():
    raise SystemExit(f'Result bundle already exists: {result}; use a clean CI checkout or move it before rerunning')
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
candidates = [device for runtime, values in devices.items() if 'iOS' in runtime for device in values
              if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit('No available iPhone simulator')
device = sorted(candidates, key=lambda d: (d['state'] != 'Booted', d['name']))[0]
result.parent.mkdir(parents=True, exist_ok=True)
try:
    # Finish simulator startup before XCTest launches its host. Let Xcode
    # ad-hoc sign simulator binaries so WebKit can resolve their entitlements.
    if device['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', device['udid']], check=True, timeout=60)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], check=True, timeout=240)
    with open('/tmp/raido-native-tests.log', 'w') as log:
        command = ['xcodebuild', '-project', str(root / 'RAIDORoster-Web2IPA/RAIDORoster.xcodeproj'),
                   '-scheme', 'RAIDORosterTests', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                   '-destination', f"platform=iOS Simulator,id={device['udid']}",
                   '-derivedDataPath', str(root / 'RAIDORoster-Web2IPA/build/NativeDerivedData'),
                   '-resultBundlePath', str(result), '-parallel-testing-enabled', 'NO',
                   'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_STYLE=Manual',
                   'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES', 'ONLY_ACTIVE_ARCH=YES',
                   '-only-testing:RAIDORosterTests/RosterBridgeTests',
                   '-only-testing:RAIDORosterTests/RosterMonthCacheTests',
                   '-only-testing:RAIDORosterTests/TodayPriorityTests',
                   '-only-testing:RAIDORosterTests/ProtectedStorageTests', 'test']
        print(f"Testing native roster ingestion and JavaScript in {device['name']}", flush=True)
        try:
            finished = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30 * 60)
        except subprocess.TimeoutExpired:
            print('Native test command exceeded its time limit', file=sys.stderr)
            finished = None
    lines = Path('/tmp/raido-native-tests.log').read_text(errors='replace').splitlines()
    print('\n'.join(lines[-100:]))
    if finished is None or finished.returncode:
        raise SystemExit(1 if finished is None else finished.returncode)
finally:
    try:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], check=False, timeout=30)
    except subprocess.TimeoutExpired:
        print('Simulator shutdown timed out; runner cleanup will finish it', file=sys.stderr)
