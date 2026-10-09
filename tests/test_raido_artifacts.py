import importlib.util
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_raido_artifacts', ROOT / 'tools/verify_raido_artifacts.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ArtifactChecks(unittest.TestCase):
    def make_ipa(self, root, **overrides):
        info = plistlib.loads((ROOT / 'RAIDORoster-Web2IPA/RAIDORoster/Info.plist').read_bytes())
        expected = module._version.version()
        info.update(CFBundleShortVersionString=expected['version'], CFBundleVersion=expected['build'],
                    CFBundleSupportedPlatforms=['iPhoneOS'], CFBundleExecutable='RAIDORoster')
        cpu = overrides.pop('cpu', 0x0100000c)
        omit = overrides.pop('omit', None)
        info.update(overrides)
        if omit: info.pop(omit)
        with zipfile.ZipFile(root / 'RAIDORoster-unsigned.ipa', 'w') as archive:
            prefix = 'Payload/RAIDORoster.app/'
            archive.writestr(prefix + 'Info.plist', plistlib.dumps(info))
            archive.writestr(prefix + 'RAIDORoster', b'\xcf\xfa\xed\xfe' + struct.pack('<I', cpu) + bytes(24))
            for name in ('RosterEnhancements.js', 'GetJetAnnouncements.json', 'OfflineLand.json',
                         'OfflinePlaceLabels.json', 'GlobalAirportIndex.json', 'AirportTimeZones.json'):
                archive.write(ROOT / 'RAIDORoster-Web2IPA/RAIDORoster' / name, prefix + name)

    def test_version_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.make_ipa(root)
            result = module.verify(root)
            self.assertEqual(result['version'], module._version.version()['version'])
            self.assertEqual(len(result['artifacts'][0]['sha256']), 64)

    def test_rejects_invalid_metadata_or_configuration(self):
        for changes in ({'CFBundleShortVersionString': '0.0.1'}, {'CFBundleVersion': '0'},
                        {'CFBundleSupportedPlatforms': ['iPhoneSimulator']}, {'cpu': 0x01000007},
                        {'omit': 'NSCameraUsageDescription'}, {'UIBackgroundModes': []},
                        {'NSLocationWhenInUseUsageDescription': 'Incorrect permission text'}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.make_ipa(root, **changes)
                with self.assertRaises(ValueError): module.verify(root)

    def test_rejects_changed_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.make_ipa(root)
            ipa = root / 'RAIDORoster-unsigned.ipa'
            with zipfile.ZipFile(ipa) as archive:
                files = {name: archive.read(name) for name in archive.namelist()}
            files['Payload/RAIDORoster.app/RosterEnhancements.js'] = b'Changed parser'
            with zipfile.ZipFile(ipa, 'w') as archive:
                for name, value in files.items(): archive.writestr(name, value)
            with self.assertRaisesRegex(ValueError, 'resource'): module.verify(root)

    def test_missing_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'Missing or empty'): module.verify(Path(directory))

    def test_configuration_versions_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / 'project.pbxproj'
            project.write_text('MARKETING_VERSION = 2.29.8; MARKETING_VERSION = 2.29.9; CURRENT_PROJECT_VERSION = 2298;')
            with self.assertRaises(ValueError): module._version.version(project)

if __name__ == '__main__': unittest.main()
