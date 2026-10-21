import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('simulator_devices', Path(__file__).resolve().parents[1] / 'tools/simulator_devices.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SimulatorSelectionTests(unittest.TestCase):
    def device(self, name, state='Shutdown', available=True):
        return {'name': name, 'state': state, 'isAvailable': available}

    def test_newest_runtime_precedes_old_booted_device(self):
        choices = {'iOS-18-6': [self.device('iPhone 16', 'Booted')],
                   'iOS-26-2': [self.device('iPhone 17 Pro Max')]}
        self.assertEqual(module.newest_iphone(choices)[0], 'iOS-26-2')

    def test_validated_profile_then_generation_precede_alphabetical_se_name(self):
        choices = {'iOS-26-2': [self.device('iPhone SE (3rd generation)'), self.device('iPhone 17'),
                               self.device('iPhone 17 Pro Max'), self.device('iPhone 17 Pro'),
                               self.device('iPhone 16 Pro')]}
        self.assertEqual(module.newest_iphone(choices)[1]['name'], 'iPhone 16 Pro')
        choices['iOS-26-2'].pop()
        self.assertEqual(module.newest_iphone(choices)[1]['name'], 'iPhone 17 Pro Max')

    def test_unavailable_phones_and_other_platforms_are_excluded(self):
        choices = {'iOS-27-0': [self.device('iPhone 18', available=False)],
                   'watchOS-26-0': [self.device('iPhone invalid')],
                   'iOS-26-2': [self.device('iPad Pro'), self.device('iPhone 17')]}
        self.assertEqual(module.newest_iphone(choices)[1]['name'], 'iPhone 17')
        with self.assertRaises(RuntimeError): module.newest_iphone({})
