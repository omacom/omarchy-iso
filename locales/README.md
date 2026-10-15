# Locale profiles

Locale profiles add language-specific input packages and first-user defaults to the existing source-based ISO build. The default build does not select a profile.

```sh
# Japanese desktop locale and Mozc input, with the installer's keyboard choice.
./bin/omarchy-iso-make --locale ja

# Also bundle a local multilingual Whisper model and configure Japanese dictation.
./bin/omarchy-iso-make --locale ja --with-dictation
```

The options can be combined with the existing channel and local-source options. Profile validation requires Python 3 on the build host. Generated filenames include the profile and, when enabled, `dictation`, so they are distinct from the default image.

## Layout

- `locales/<language>/profile.json`: locale, input method, extra packages, and optional dictation language. Japanese is currently the only shipped profile.
- `builder/prepare-locale.py`: validate and stage the selected profile and packages into the normal build.
- `builder/download-dictation.sh`: download and verify the optional shared multilingual Whisper model.
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/localization.py`: apply the selected profile after user provisioning and before the factory snapshot.
- `configs/airootfs/usr/share/omarchy-iso/locale_defaults.py`: initialize only the installation user's configuration.

Language identifiers use language codes (`ja`), not country codes (`jp`). The POSIX locale (`ja_JP.UTF-8`), Fcitx input method (`mozc`), and dictation language (`ja`) are separate fields. Physical keyboard selection stays with the installer. Do not copy the builder or user initializer to add another language.

Profiles are reviewed repository data, not user-supplied scripts. Package names are validated and added to both the target package list and the normal offline-mirror resolution. Package versions follow the selected upstream channel; this build does not repack a pinned release ISO.

## Scope

A selected profile sets the installation user's locale and Fcitx input defaults. It does not change `/etc/locale.conf`, the live installer's display language, other accounts, or Omarchy's own translations. Locale data and optional model files are shared resources; user settings are initialized once using `~/.local/state/omarchy/done/locale-defaults-v1`.

Dictation is optional. Without `--with-dictation`, profile initialization does not change voice settings or enable its service. With it, the installer adds a user-owned Voxtype service and the local `small` model; no API key is required. The model is checksum-pinned independently of the selected locale. Voice packages follow the selected package channel.

No third-party bar plugin is bundled or enabled. Fcitx input works without a bar plugin; users can install an indicator separately.

Deferred/OEM provisioning with a selected profile is not yet supported: it requires a corresponding first-user hook in the Omarchy runtime. The orchestrator rejects that combination before running installation phases or changing disks. Default images retain upstream deferred-provisioning behavior. Existing installations and factory-reset reapplication are outside this change.

## Tests

```sh
python -m unittest discover -s test/unit -p 'test_*.py'
bash -n bin/omarchy-iso-make builder/build-iso.sh builder/download-dictation.sh
```

Tests cover the public build CLI, profile staging, optional dictation, per-user configuration, repeat initialization, default behavior, and rejection before installation phases. A synthetic Korean profile exercises the same builder and initializer; this is not a claim of Korean end-to-end support.
