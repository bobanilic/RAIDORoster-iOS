import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('verify_raido_artifacts', Path(__file__).resolve().parents[1] / 'tools/verify_raido_artifacts.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ArtifactChecks(unittest.TestCase):
    def make_pair(self, root, version='2.26.1', platform='iPhoneOS', camera=True):
        info = {
            'CFBundleShortVersionString': version,
            'CFBundleSupportedPlatforms': [platform], 'CFBundleExecutable': 'RAIDORoster',
            'NSFaceIDUsageDescription': 'Synthetic test',
            'NSMotionUsageDescription': 'Synthetic test',
            'NSLocationAlwaysAndWhenInUseUsageDescription': 'Synthetic test',
            'UIBackgroundModes': ['location'],
            'NSCalendarsFullAccessUsageDescription': 'Synthetic test',
            'NSLocationWhenInUseUsageDescription': 'Synthetic test'
        }
        if camera:
            info['NSCameraUsageDescription'] = 'Synthetic test'
        ipa = root / 'RAIDORoster-unsigned.ipa'
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('Payload/RAIDORoster.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/RAIDORoster.app/RAIDORoster', b'\xcf\xfa\xed\xfe' + bytes(32))
        with zipfile.ZipFile(root / 'RAIDO-2.26.1-fleet-responsiveness-IPA.zip', 'w') as archive:
            archive.write(ipa, ipa.name)

    def test_pair_and_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_pair(root)
            result = module.verify(root)
            self.assertEqual(result['version'], '2.26.1')
            self.assertEqual(len(result['artifacts']), 2)
            self.assertEqual(len(result['artifacts'][0]['sha256']), 64)

    def test_rejects_wrong_version_platform_and_missing_camera(self):
        for kwargs in ({'version': '2.19.7'}, {'platform': 'iPhoneSimulator'}, {'camera': False}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_pair(root, **kwargs)
                with self.assertRaises(ValueError):
                    module.verify(root)

    def test_rejects_different_ipa_in_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_pair(root)
            with zipfile.ZipFile(root / 'RAIDO-2.26.1-fleet-responsiveness-IPA.zip', 'w') as archive:
                archive.writestr('RAIDORoster-unsigned.ipa', b'wrong build')
            with self.assertRaisesRegex(ValueError, 'different IPA'):
                module.verify(root)

    def test_missing_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'Missing or empty'):
                module.verify(Path(directory))


if __name__ == '__main__':
    unittest.main()
