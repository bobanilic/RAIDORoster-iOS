"""Verify the built IPA against the committed project and privacy configuration."""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import struct
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('raido_version', Path(__file__).with_name('version.py'))
_version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_version)

def arm64_device_binary(binary):
    if len(binary) < 32:
        return False
    if binary[:4] == b'\xcf\xfa\xed\xfe':
        return struct.unpack_from('<I', binary, 4)[0] == 0x0100000c
    if binary[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', binary, 4)[0]
        size = 32 if binary[:4] == b'\xca\xfe\xba\xbf' else 20
        if count > 32 or len(binary) < 8 + count * size:
            return False
        return any(struct.unpack_from('>I', binary, 8 + i * size)[0] == 0x0100000c for i in range(count))
    return False

def verify(root: Path, expected_version=None, expected_build=None) -> dict:
    expected = _version.version()
    release = expected_version or expected['version']
    build = expected_build or expected['build']
    ipa = root / 'RAIDORoster-unsigned.ipa'
    if not ipa.is_file() or ipa.stat().st_size == 0:
        raise ValueError('Missing or empty IPA')
    privacy = plistlib.loads((ROOT / 'RAIDORoster-Web2IPA/RAIDORoster/Info.plist').read_bytes())
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA CRC validation failed')
        prefix = 'Payload/RAIDORoster.app/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleShortVersionString') != release or str(info.get('CFBundleVersion')) != build:
            raise ValueError('IPA version/build differs from Xcode project')
        if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
            raise ValueError('IPA is not an iPhoneOS build')
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or '/' in executable or not executable:
            raise ValueError('Invalid app executable metadata')
        if not arm64_device_binary(archive.read(prefix + executable)):
            raise ValueError('App executable is missing or not ARM64 Mach-O')
        for key, value in privacy.items():
            if info.get(key) != value:
                raise ValueError(f'Packaged configuration differs from source: {key}')
        for resource in ('RosterEnhancements.js', 'GetJetAnnouncements.json', 'OfflineLand.json',
                         'OfflinePlaceLabels.json', 'GlobalAirportIndex.json', 'AirportTimeZones.json'):
            if archive.read(prefix + resource) != (ROOT / 'RAIDORoster-Web2IPA/RAIDORoster' / resource).read_bytes():
                raise ValueError(f'Packaged resource differs from committed source: {resource}')
    sha = os.environ.get('GITHUB_SHA') or os.environ.get('CM_COMMIT')
    if not sha:
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if len(sha) != 40 or any(c not in '0123456789abcdefABCDEF' for c in sha):
        raise ValueError('Unexpected commit metadata')
    return {'version': release, 'build': build, 'commit': sha,
            'artifacts': [{'name': ipa.name, 'bytes': ipa.stat().st_size,
                           'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest()}]}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT / 'RAIDORoster-Web2IPA')
    args = parser.parse_args()
    result = verify(args.root)
    (args.root / 'artifact-verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"Verified RAIDO {result['version']}/{result['build']}: ARM64 IPA, project privacy settings and committed resources")
