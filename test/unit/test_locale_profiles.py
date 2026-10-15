"""Locale selection stays opt-in and independent from dictation and keyboards."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
ISO = ROOT / 'configs/airootfs/usr/share/omarchy-iso'


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LocaleProfilesTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ISO / 'locale_defaults.py').exists(), 'Shared locale initialization is missing')
        self.defaults = load(ISO / 'locale_defaults.py')
        self.builder = load(ROOT / 'builder/prepare-locale.py')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.live = self.root / 'airootfs'
        self.shared = self.live / 'usr/share/omarchy-iso'
        self.shared.mkdir(parents=True)
        (self.shared / 'omarchy-base.packages').write_text('fcitx5\n')

    def stage(self, name='ja', dictation=False):
        return self.builder.prepare(ROOT / 'locales', name, self.live, dictation)

    def test_default_build_has_no_profile_or_extra_packages(self):
        self.stage('')
        self.assertFalse((self.shared / 'locale-profile.json').exists())
        self.assertEqual((self.shared / 'omarchy-base.packages').read_text(), 'fcitx5\n')

    def test_japanese_text_input_does_not_bundle_dictation_or_plugins(self):
        profile = self.stage()
        packages = (self.shared / 'omarchy-base.packages').read_text().splitlines()
        self.assertIn('fcitx5-mozc', packages)
        self.assertNotIn('voxtype-bin', packages)
        self.assertEqual(profile['locale'], 'ja_JP.UTF-8')
        self.assertFalse(profile['dictation'])
        self.assertFalse((self.live / 'usr/local/share/omarchy-jp').exists())

    def test_dictation_requires_a_profile_and_adds_packages_when_selected(self):
        with self.assertRaises(ValueError):
            self.stage('', True)
        profile = self.stage(dictation=True)
        self.assertTrue(profile['dictation'])
        self.assertIn('voxtype-bin', (self.shared / 'omarchy-base.packages').read_text())

    def test_unknown_and_path_traversal_profiles_fail_without_changes(self):
        for name in ('fr', '../ja', '/tmp/ja', 'ja;id'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.stage(name)
        self.assertEqual((self.shared / 'omarchy-base.packages').read_text(), 'fcitx5\n')

    def test_second_language_uses_same_builder_and_initializer(self):
        profiles = self.root / 'locales'
        (profiles / 'ko').mkdir(parents=True)
        (profiles / 'ko/profile.json').write_text(json.dumps({
            'locale': 'ko_KR.UTF-8', 'input_method': 'hangul',
            'packages': ['fcitx5-hangul'], 'dictation_language': 'ko',
        }))
        profile = self.builder.prepare(profiles, 'ko', self.live, False)
        home = self.root / 'home'
        self.defaults.configure_user(home, profile, 'us')
        self.assertEqual((home / '.config/locale.conf').read_text(), 'LANG=ko_KR.UTF-8\n')
        self.assertIn('Name=hangul', (home / '.config/fcitx5/profile').read_text())
        self.assertFalse((home / '.config/voxtype').exists())

    def test_user_defaults_preserve_keyboard_other_settings_and_repeat_changes(self):
        profile = self.stage()
        home = self.root / 'home'
        (home / '.config/voxtype').mkdir(parents=True)
        voice = home / '.config/voxtype/config.toml'
        voice.write_text('engine="soniox"\n')
        self.defaults.configure_user(home, profile, 'us')
        self.assertIn('Name=keyboard-us', (home / '.config/fcitx5/profile').read_text())
        self.assertEqual(voice.read_text(), 'engine="soniox"\n')
        self.assertFalse((home / '.config/omarchy/shell.json').exists())
        locale = home / '.config/locale.conf'
        locale.write_text('LANG=en_US.UTF-8\n')
        self.defaults.configure_user(home, profile, 'jp')
        self.assertEqual(locale.read_text(), 'LANG=en_US.UTF-8\n')

    def test_session_and_user_service_locale_read_the_same_user_file(self):
        import os
        import subprocess
        profile = self.stage()
        home = self.root / 'home'
        self.defaults.configure_user(home, profile, 'us')
        locale = home / '.config/locale.conf'
        self.assertEqual((home / '.config/environment.d/20-omarchy-locale.conf').resolve(), locale)
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), LANG='en_US.UTF-8')
        command = ['sh', '-c', '. "$HOME/.config/uwsm/env.d/20-omarchy-locale"; printf %s "$LANG"']
        self.assertEqual(subprocess.check_output(command, env=env, text=True), 'ja_JP.UTF-8')
        locale.write_text('LANG=en_US.UTF-8\n')
        self.assertEqual(subprocess.check_output(command, env=env, text=True), 'en_US.UTF-8')

    def test_keyboard_layout_reads_installer_vconsole_configuration(self):
        profile = self.stage()
        config = self.root / 'vconsole.conf'
        for value in ('jp', '"de"', "'gb'"):
            with self.subTest(value=value):
                config.write_text(f'KEYMAP=ignored-console-keymap\nXKBLAYOUT={value}\n')
                with patch.object(self.defaults, 'Path', return_value=config) as path:
                    layout = self.defaults.keyboard_layout()
                path.assert_called_once_with('/etc/vconsole.conf')
                expected = value.strip('\"\'')
                self.assertEqual(layout, expected)
                home = self.root / expected
                self.defaults.configure_user(home, profile, layout)
                self.assertIn(f'Name=keyboard-{expected}', (home / '.config/fcitx5/profile').read_text())

    def test_keyboard_layout_defaults_when_xkb_layout_is_unavailable(self):
        config = self.root / 'vconsole.conf'
        with patch.object(self.defaults, 'Path', return_value=config):
            self.assertEqual(self.defaults.keyboard_layout(), 'us')
            for text in ('KEYMAP=jp106\n', '#XKBLAYOUT=jp\n', 'XKBLAYOUT=\n'):
                config.write_text(text)
                self.assertEqual(self.defaults.keyboard_layout(), 'us')

    def test_selected_dictation_uses_profile_language(self):
        import tomllib
        profile = self.stage(dictation=True)
        home = self.root / 'home'
        self.defaults.configure_user(home, profile, 'jp')
        voice = tomllib.loads((home / '.config/voxtype/config.toml').read_text())
        self.assertEqual(voice['whisper']['language'], 'ja')
        self.assertEqual(voice['output']['mode'], 'paste')
        self.assertTrue((home / '.config/systemd/user/graphical-session.target.wants/voxtype.service').is_symlink())

    def test_preflight_rejects_deferred_only_for_localized_images(self):
        sys.path.insert(0, str(ISO))
        self.addCleanup(sys.path.remove, str(ISO))
        module = load(ISO / 'orchestrator/localization.py')
        ctx = SimpleNamespace(username='', defer_provisioning=True)
        with patch.object(module, 'PROFILE', self.shared / 'locale-profile.json'):
            module.validate_locale_install(ctx)
            self.stage()
            with self.assertRaisesRegex(RuntimeError, 'deferred'):
                module.validate_locale_install(ctx)

    def test_installer_rejects_deferred_before_running_any_phase(self):
        import types
        sys.path.insert(0, str(ISO))
        self.addCleanup(sys.path.remove, str(ISO))
        sys.modules.setdefault('orchestrator.archinstall_adapter', types.ModuleType('orchestrator.archinstall_adapter'))
        from orchestrator import main, localization, phases_impl
        self.stage()
        ctx = SimpleNamespace(username='', defer_provisioning=True)
        with patch.object(localization, 'PROFILE', self.shared / 'locale-profile.json'), patch.object(main.InstallContext, 'from_env', return_value=ctx), patch.object(main, 'run') as run, patch.object(phases_impl, 'boost_cpu_governor') as boost:
            self.assertEqual(main.main(), 2)
            run.assert_not_called()
            boost.assert_not_called()

    def test_locale_phase_runs_after_user_before_factory_snapshot(self):
        import types
        sys.path.insert(0, str(ISO))
        self.addCleanup(sys.path.remove, str(ISO))
        sys.modules.setdefault('orchestrator.archinstall_adapter', types.ModuleType('orchestrator.archinstall_adapter'))
        from orchestrator import main
        names = [function.__name__ for _, function in main.build_phases(None)]
        self.assertLess(names.index('run_chroot_finalizer'), names.index('configure_locale'))
        self.assertLess(names.index('configure_locale'), names.index('create_factory_snapshot'))

    def test_installer_only_initializes_selected_user_without_changing_system_locale(self):
        sys.path.insert(0, str(ISO))
        self.addCleanup(sys.path.remove, str(ISO))
        module = load(ISO / 'orchestrator/localization.py')
        self.stage()
        target = self.root / 'target'
        (target / 'etc').mkdir(parents=True)
        (target / 'etc/locale.conf').write_text('LANG=en_US.UTF-8\n')
        (target / 'etc/locale.gen').write_text('#ja_JP.UTF-8 UTF-8\n')
        ctx = SimpleNamespace(username='alice', defer_provisioning=False, target=target)
        with patch.object(module, 'PROFILE', self.shared / 'locale-profile.json'), patch.object(module.subprocess, 'run') as run:
            module.configure_locale(ctx)
        self.assertEqual((target / 'etc/locale.conf').read_text(), 'LANG=en_US.UTF-8\n')
        self.assertIn('ja_JP.UTF-8 UTF-8', (target / 'etc/locale.gen').read_text().splitlines())
        command = run.call_args.args[0]
        self.assertIn('alice', command)
        self.assertIn('runuser', command)
