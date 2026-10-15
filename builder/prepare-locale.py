#!/usr/bin/env python3
"""Stage a selected locale into the ordinary source-based ISO build."""
import argparse
import json
import re
from pathlib import Path


def load_profile(profiles, name, dictation=False):
    if not name:
        if dictation:
            raise ValueError('--with-dictation requires --locale')
        return None
    if not re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z0-9]+)*', name):
        raise ValueError(f'Invalid locale profile: {name}')
    path = profiles / name / 'profile.json'
    if not path.is_file():
        raise ValueError(f'Unknown locale profile: {name}')
    profile = json.loads(path.read_text())
    if not re.fullmatch(r'[a-z]{2,3}_[A-Z]{2}\.UTF-8', profile['locale']):
        raise ValueError('Profile must specify a UTF-8 locale')
    if not re.fullmatch(r'[a-z0-9_-]+', profile['input_method']):
        raise ValueError('Invalid input method')
    if not isinstance(profile['packages'], list) or not all(
        isinstance(package, str) and re.fullmatch(r'[a-z0-9][a-z0-9@._+-]*', package)
        for package in profile['packages']
    ):
        raise ValueError('Invalid locale packages')
    if dictation and not re.fullmatch(r'[a-z]{2,3}', profile.get('dictation_language', '')):
        raise ValueError('This profile has no dictation language')
    return dict(profile, id=name, dictation=bool(dictation))


def prepare(profiles, name, root, dictation=False):
    profile = load_profile(profiles, name, dictation)
    if profile is None:
        return None
    shared = root / 'usr/share/omarchy-iso'
    packages = shared / 'omarchy-base.packages'
    lines = packages.read_text().splitlines()
    extras = profile['packages'] + (['voxtype-bin', 'wtype', 'wl-clipboard'] if dictation else [])
    for package in extras:
        if package not in lines:
            lines.append(package)
    packages.write_text('\n'.join(lines) + '\n')
    (shared / 'locale-profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    return profile


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profiles', type=Path, required=True)
    parser.add_argument('--locale', default='')
    parser.add_argument('--with-dictation', action='store_true')
    parser.add_argument('--root', type=Path)
    args = parser.parse_args()
    try:
        if args.root:
            prepare(args.profiles, args.locale, args.root, args.with_dictation)
        else:
            load_profile(args.profiles, args.locale, args.with_dictation)
    except (ValueError, KeyError) as exc:
        parser.error(str(exc))
