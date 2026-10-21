"""Deterministic simulator selection shared by native and UI runners."""
import re


def newest_iphone(devices):
    choices = [(runtime, device) for runtime, group in devices.items() if 'iOS-' in runtime
               for device in group if device.get('isAvailable') and device['name'].startswith('iPhone')]
    if not choices:
        raise RuntimeError('No available iPhone simulator')

    def rank(choice):
        runtime, device = choice
        version = tuple(int(part) for part in re.findall(r'\d+', runtime.rsplit('iOS-', 1)[1]))
        # Never accidentally select an old runtime because its phone name sorts first.
        return version, device['state'] == 'Booted', device['name']

    return max(choices, key=rank)
