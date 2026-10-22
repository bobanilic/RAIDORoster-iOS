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
    def binary(self, cpu=0x0100000c, platform=2, signed=False):
        commands = struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x1a0000, 0)
        if signed: commands += struct.pack('<4I', 0x1d, 16, 0, 0)
        return struct.pack('<8I', 0xfeedfacf, cpu, 0, 2, 2 if signed else 1, len(commands), 0, 0) + commands

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
            archive.writestr(prefix + 'RAIDORoster', self.binary(cpu))
            widget = {'CFBundleShortVersionString':expected['version'],'CFBundleVersion':expected['build'],
                      'CFBundleExecutable':'RAIDODutyWidget','CFBundleIdentifier':'com.bobanilic.raidoroster.DutyWidget',
                      'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
            widget_prefix = prefix + 'PlugIns/RAIDODutyWidget.appex/'
            archive.writestr(widget_prefix+'Info.plist',plistlib.dumps(widget))
            archive.writestr(widget_prefix+'RAIDODutyWidget',self.binary())
            for name in module.RESOURCES:
                archive.write(ROOT / 'RAIDORoster-Web2IPA/RAIDORoster' / name, prefix + name)

    def test_version_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.make_ipa(root)
            result = module.verify(root)
            self.assertEqual(result['version'], module._version.version()['version'])
            self.assertEqual(len(result['artifacts'][0]['sha256']), 64)
            self.assertEqual(result['signing'], 'unsigned')
            self.assertEqual(set(result['resourceSHA256']), set(module.RESOURCES))
            self.assertTrue(all(len(value) == 64 for value in result['resourceSHA256'].values()))

    def test_rejects_arm64_simulator_and_signed_or_malformed_binaries(self):
        for value in [self.binary(platform=7), self.binary(signed=True), self.binary()[:-1],
                      struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 0, 0, 0)]:
            with self.subTest(binary=value):
                self.assertFalse(module.arm64_device_binary(value))
        for magic, fmt in [(0xcafebabe, '>IIIII'), (0xcafebabf, '>IIQQII')]:
            header = struct.pack('>II', magic, 1)
            size = struct.calcsize(fmt)
            value = self.binary()
            fields = [0x0100000c, 0, 8 + size, len(value), 0] + ([0] if magic == 0xcafebabf else [])
            fat = header + struct.pack(fmt, *fields) + value
            self.assertTrue(module.arm64_device_binary(fat))
            self.assertFalse(module.arm64_device_binary(fat[:-1]))

    def test_rejects_signing_material(self):
        for name in ['_CodeSignature/CodeResources', 'embedded.mobileprovision']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.make_ipa(root)
                with zipfile.ZipFile(root / 'RAIDORoster-unsigned.ipa', 'a') as archive:
                    archive.writestr('Payload/RAIDORoster.app/' + name, b'signing material')
                with self.assertRaisesRegex(ValueError, 'unsigned'): module.verify(root)

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

    def test_rejects_missing_lock_screen_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.make_ipa(root)
            ipa = root / 'RAIDORoster-unsigned.ipa'
            with zipfile.ZipFile(ipa) as archive:
                files = {name:archive.read(name) for name in archive.namelist() if '.appex/' not in name}
            with zipfile.ZipFile(ipa,'w') as archive:
                for name,value in files.items(): archive.writestr(name,value)
            with self.assertRaisesRegex(ValueError,'extension missing'): module.verify(root)

    def test_missing_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'Missing or empty'): module.verify(Path(directory))

    def test_configuration_versions_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / 'project.pbxproj'
            project.write_text('MARKETING_VERSION = 2.29.8; MARKETING_VERSION = 2.29.9; CURRENT_PROJECT_VERSION = 2298;')
            with self.assertRaises(ValueError): module._version.version(project)

if __name__ == '__main__': unittest.main()
