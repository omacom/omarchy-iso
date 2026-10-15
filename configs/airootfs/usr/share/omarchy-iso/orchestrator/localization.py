"""Apply the image's optional locale profile after normal user provisioning."""
import json
import shutil
import subprocess
from pathlib import Path

PROFILE = Path('/usr/share/omarchy-iso/locale-profile.json')
ASSETS = Path('/usr/local/share/omarchy-locale')


def validate_locale_install(ctx):
    if PROFILE.exists() and (ctx.defer_provisioning or not ctx.username):
        raise RuntimeError('Locale profiles do not yet support deferred provisioning. Use a standard image or create the installation user now.')


def configure_locale(ctx):
    if not PROFILE.exists():
        return
    validate_locale_install(ctx)
    profile = json.loads(PROFILE.read_text())
    destination = ctx.target / ASSETS.relative_to('/')
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PROFILE, destination / 'profile.json')
    shutil.copy2(Path(__file__).resolve().parents[1] / 'locale_defaults.py', destination / 'locale_defaults.py')
    if profile['dictation']:
        shutil.copy2(ASSETS / 'ggml-small.bin', destination / 'ggml-small.bin')
        shutil.copy2(ASSETS / 'WHISPER-LICENSE', destination / 'WHISPER-LICENSE')
    locale_gen = ctx.target / 'etc/locale.gen'
    lines = locale_gen.read_text().splitlines()
    entry = f"{profile['locale']} UTF-8"
    if entry not in lines:
        lines.append(entry)
    locale_gen.write_text('\n'.join(lines) + '\n')
    subprocess.run(['arch-chroot', str(ctx.target), 'locale-gen'], check=True)
    subprocess.run(['arch-chroot', str(ctx.target), 'runuser', '-u', ctx.username, '--',
                    'python', str(ASSETS / 'locale_defaults.py'), '--user'], check=True)
