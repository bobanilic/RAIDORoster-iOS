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
    with open('/tmp/raido-native-tests.log', 'w') as log:
        command = ['xcodebuild', '-project', str(root / 'RAIDORoster-Web2IPA/RAIDORoster.xcodeproj'),
                   '-scheme', 'RAIDORosterTests', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                   '-destination', f"platform=iOS Simulator,id={device['udid']}",
                   '-derivedDataPath', str(root / 'RAIDORoster-Web2IPA/build/NativeDerivedData'),
                   '-resultBundlePath', str(result), '-parallel-testing-enabled', 'NO',
                   'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'test']
        print(f"Testing native roster ingestion and JavaScript in {device['name']}", flush=True)
        try:
            finished = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=22 * 60)
        except subprocess.TimeoutExpired:
            print('Native test command exceeded its time limit', file=sys.stderr)
            finished = None
    lines = Path('/tmp/raido-native-tests.log').read_text(errors='replace').splitlines()
    print('\n'.join(lines[-100:]))
    if finished is None or finished.returncode:
        raise SystemExit(1 if finished is None else finished.returncode)
finally:
    subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], check=False)
