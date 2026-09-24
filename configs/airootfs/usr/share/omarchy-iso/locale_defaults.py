"""Initialize the installation user's locale and input settings once."""
import json
import re
import sys
from pathlib import Path

ASSETS = Path('/usr/local/share/omarchy-locale')


def write(home, relative, text):
    path = home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def configure_user(home, profile, layout):
    marker = home / '.local/state/omarchy/done/locale-defaults-v1'
    if marker.exists():
        return False
    write(home, '.config/locale.conf', f"LANG={profile['locale']}\n")
    environment = home / '.config/environment.d/20-omarchy-locale.conf'
    environment.parent.mkdir(parents=True, exist_ok=True)
    if not environment.is_symlink():
        environment.symlink_to('../locale.conf')
    write(home, '.config/uwsm/env.d/20-omarchy-locale', '. "${XDG_CONFIG_HOME:-$HOME/.config}/locale.conf"\nexport LANG\n')
    method = profile['input_method']
    write(home, '.config/fcitx5/profile', f'''[Groups/0]
Name=Default
Default Layout={layout}
DefaultIM={method}

[Groups/0/Items/0]
Name=keyboard-{layout}
Layout=

[Groups/0/Items/1]
Name={method}
Layout=

[GroupOrder]
0=Default
''')
    if profile['dictation']:
        configure_dictation(home, profile['dictation_language'])
    write(home, '.local/state/omarchy/done/locale-defaults-v1', '')
    return True


def configure_dictation(home, language):
    write(home, '.config/voxtype/config.toml', f'''engine = "whisper"
state_file = "auto"
[hotkey]
enabled = false
[audio]
device = "default"
sample_rate = 16000
max_duration_secs = 60
pause_media = true
[whisper]
model = "small"
language = "{language}"
translate = false
[output]
mode = "paste"
paste_keys = "ctrl+shift+v"
fallback_to_clipboard = true
[output.notification]
on_recording_start = false
on_recording_stop = false
on_transcription = false
''')
    model = home / '.local/share/voxtype/models/ggml-small.bin'
    model.parent.mkdir(parents=True, exist_ok=True)
    if not model.exists() and not model.is_symlink():
        model.symlink_to(ASSETS / 'ggml-small.bin')
    # User-owned unit: do not override the service for other accounts.
    write(home, '.config/systemd/user/voxtype.service', '''[Unit]
Description=Offline dictation
PartOf=graphical-session.target
After=graphical-session.target pipewire.service pipewire-pulse.service
ConditionEnvironment=WAYLAND_DISPLAY
[Service]
Type=simple
ExecStart=/usr/bin/voxtype daemon
Restart=on-failure
RestartSec=5
Environment=XDG_RUNTIME_DIR=%t
[Install]
WantedBy=graphical-session.target
''')
    service = home / '.config/systemd/user/graphical-session.target.wants/voxtype.service'
    service.parent.mkdir(parents=True, exist_ok=True)
    if not service.is_symlink():
        service.symlink_to('../voxtype.service')
    write(home, '.local/state/omarchy/done/voxtype-install-invitation', '')


def keyboard_layout():
    # The installer writes XKB settings here, without generating Xorg config.
    xkb = Path('/etc/vconsole.conf')
    if xkb.exists():
        match = re.search(r"^XKBLAYOUT=[\"']?([a-z0-9_-]+)[\"']?$", xkb.read_text(), re.MULTILINE)
        if match:
            return match[1]
    return 'us'


if __name__ == '__main__':
    if sys.argv[1:] != ['--user']:
        raise SystemExit('Pass --user to initialize the current installation account.')
    configure_user(Path.home(), json.loads((ASSETS / 'profile.json').read_text()), keyboard_layout())
