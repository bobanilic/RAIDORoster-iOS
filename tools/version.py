"""Read the one authoritative app version from the Xcode project."""
import argparse
import json
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1] / 'RAIDORoster-Web2IPA/RAIDORoster.xcodeproj/project.pbxproj'

def version(project=PROJECT):
    text = Path(project).read_text()
    def setting(name):
        values = set(re.findall(r'\b' + name + r'\s*=\s*([^;]+);', text))
        values = {value.strip().strip('"') for value in values}
        if len(values) != 1:
            raise ValueError(f'{name} must match in all configurations: {values}')
        return values.pop()
    release, build = setting('MARKETING_VERSION'), setting('CURRENT_PROJECT_VERSION')
    if not re.fullmatch(r'\d+\.\d+\.\d+', release) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid release or build number')
    return {'version': release, 'build': build}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--field', choices=['version', 'build'])
    args = parser.parse_args()
    data = version()
    print(data[args.field] if args.field else json.dumps(data))
