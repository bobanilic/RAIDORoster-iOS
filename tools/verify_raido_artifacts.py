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
    """Require an ARM64 executable whose load commands identify iPhoneOS.

    CPU type alone also accepts ARM64 simulator binaries. Validate bounds and
    reject embedded code signatures rather than relying on the IPA filename.
    """
    if len(binary) < 32:
        return False
    if binary[:4] == b'\xcf\xfa\xed\xfe':
        _, cpu, _, filetype, count, size, _, _ = struct.unpack_from('<8I', binary)
        if cpu != 0x0100000c or filetype != 2 or size > len(binary) - 32 or count > size // 8:
            return False
        offset, device = 32, False
        for _ in range(count):
            if offset + 8 > 32 + size:
                return False
            command, length = struct.unpack_from('<II', binary, offset)
            if length < 8 or offset + length > 32 + size:
                return False
            if command == 0x1d:  # LC_CODE_SIGNATURE
                return False
            if command == 0x32:  # LC_BUILD_VERSION
                if length < 24 or struct.unpack_from('<I', binary, offset + 8)[0] != 2:
                    return False
                device = True
            if command == 0x25:  # LC_VERSION_MIN_IPHONEOS, pre-build-version toolchains
                if length < 16:
                    return False
                device = True
            offset += length
        return device and offset == 32 + size
    if binary[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', binary, 4)[0]
        size = 32 if binary[:4] == b'\xca\xfe\xba\xbf' else 20
        if count > 32 or len(binary) < 8 + count * size:
            return False
        found = False
        for index in range(count):
            offset = 8 + index * size
            cpu = struct.unpack_from('>I', binary, offset)[0]
            start, length = struct.unpack_from('>QQ' if size == 32 else '>II', binary, offset + 8)
            if start < 8 + count * size or start + length > len(binary):
                return False
            if cpu == 0x0100000c:
                if not arm64_device_binary(binary[start:start + length]):
                    return False
                found = True
        return found
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
        if any('/_CodeSignature/' in name or name.endswith('/embedded.mobileprovision') for name in archive.namelist()):
            raise ValueError('Expected unsigned IPA without signatures or provisioning profiles')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleShortVersionString') != release or str(info.get('CFBundleVersion')) != build:
            raise ValueError('IPA version/build differs from Xcode project')
        if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
            raise ValueError('IPA is not an iPhoneOS build')
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or '/' in executable or not executable:
            raise ValueError('Invalid app executable metadata')
        if not arm64_device_binary(archive.read(prefix + executable)):
            raise ValueError('App executable is not unsigned ARM64 iPhoneOS Mach-O')
        for key, value in privacy.items():
            if info.get(key) != value:
                raise ValueError(f'Packaged configuration differs from source: {key}')
        widget_prefix = prefix + 'PlugIns/RAIDODutyWidget.appex/'
        try:
            widget = plistlib.loads(archive.read(widget_prefix + 'Info.plist'))
            widget_executable = widget.get('CFBundleExecutable')
            if not isinstance(widget_executable, str) or '/' in widget_executable or not widget_executable:
                raise ValueError('Invalid Lock Screen extension executable')
            if not arm64_device_binary(archive.read(widget_prefix + widget_executable)):
                raise ValueError('Lock Screen extension is not unsigned ARM64 iPhoneOS Mach-O')
        except KeyError as error:
            raise ValueError('Lock Screen extension missing from IPA') from error
        if widget.get('CFBundleShortVersionString') != release or str(widget.get('CFBundleVersion')) != build:
            raise ValueError('Lock Screen extension version mismatch')
        if widget.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
            raise ValueError('Invalid Lock Screen extension point')
        if widget.get('CFBundleIdentifier') != 'com.bobanilic.raidoroster.DutyWidget':
            raise ValueError('Invalid Lock Screen extension identifier')
        for resource in ('RosterEnhancements.js', 'GetJetAnnouncements.json', 'OfflineLand.json',
                         'OfflinePlaceLabels.json', 'GlobalAirportIndex.json', 'AirportTimeZones.json'):
            if archive.read(prefix + resource) != (ROOT / 'RAIDORoster-Web2IPA/RAIDORoster' / resource).read_bytes():
                raise ValueError(f'Packaged resource differs from committed source: {resource}')
    try:
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        sha = os.environ.get('GITHUB_SHA') or os.environ.get('CM_COMMIT') or ''
    if len(sha) != 40 or any(c not in '0123456789abcdefABCDEF' for c in sha):
        raise ValueError('Unexpected commit metadata')
    return {'version': release, 'build': build, 'commit': sha,
            'platform': 'iPhoneOS', 'architecture': 'arm64', 'signing': 'unsigned',
            'widgetExtension': 'RAIDODutyWidget.appex', 'resourcesMatchSource': True,
            'artifacts': [{'name': ipa.name, 'bytes': ipa.stat().st_size,
                           'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest()}]}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT / 'RAIDORoster-Web2IPA')
    args = parser.parse_args()
    result = verify(args.root)
    (args.root / 'artifact-verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"Verified RAIDO {result['version']}/{result['build']}: ARM64 IPA, project privacy settings and committed resources")
