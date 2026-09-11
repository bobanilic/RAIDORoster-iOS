"""Validate the release pair without extracting or printing application data."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import zipfile


def verify(root: Path) -> dict:
    ipa = root / 'RAIDORoster-unsigned.ipa'
    bundle = root / 'RAIDO-2.23.0-fleet-v2-review-IPA.zip'
    for path in (ipa, bundle):
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty artifact: {path.name}')
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA CRC validation failed')
        prefix = 'Payload/RAIDORoster.app/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleShortVersionString') != '2.23.0':
            raise ValueError('IPA version is not 2.23.0')
        if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
            raise ValueError('IPA is not an iPhoneOS build')
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or '/' in executable or not executable:
            raise ValueError('Invalid app executable metadata')
        binary = archive.read(prefix + executable)
        if len(binary) < 32 or binary[:4] not in (
            b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
            b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
            b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'
        ):
            raise ValueError('App executable is missing or not Mach-O')
        for key in ('NSFaceIDUsageDescription', 'NSCameraUsageDescription',
                    'NSCalendarsFullAccessUsageDescription', 'NSLocationWhenInUseUsageDescription'):
            if not info.get(key):
                raise ValueError(f'Missing required usage description: {key}')
    ipa_hash = hashlib.sha256(ipa.read_bytes()).hexdigest()
    with zipfile.ZipFile(bundle) as archive:
        if archive.testzip() is not None or archive.namelist() != [ipa.name]:
            raise ValueError('Review ZIP must contain exactly the unsigned IPA')
        if hashlib.sha256(archive.read(ipa.name)).hexdigest() != ipa_hash:
            raise ValueError('Review ZIP contains a different IPA')
    commit = os.environ.get('CM_COMMIT', '')
    if commit and (len(commit) != 40 or any(c not in '0123456789abcdefABCDEF' for c in commit)):
        raise ValueError('Unexpected commit metadata')
    return {
        'version': '2.23.0', 'commit': commit or None,
        'artifacts': [
            {'name': path.name, 'bytes': path.stat().st_size,
             'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in (ipa, bundle)
        ]
    }


if __name__ == '__main__':
    result = verify(Path.cwd())
    Path('artifact-verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Verified RAIDO 2.23.0 iPhoneOS executable, permissions, IPA and matching review ZIP')
