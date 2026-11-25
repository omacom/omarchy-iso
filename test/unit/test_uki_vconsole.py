"""The pre-built UKI gets this install's keyboard layout in place.

Its initramfs is built with the image and comes up in us. The disk password
prompt runs from it, so an install on another layout either has that layout
in the initramfs or locks its owner out (upstream omarchy#8196). Building a
UKI for it on the target costs 4.7 s; the image reserves room instead, and
the installer writes the install's keyboard settings into it. Tested here:
the write is in place and only where the room is, it refuses instead of
corrupting, the image build reserves exactly the room the installer looks
for, a real mkinitcpio keeps that room uncompressed, and the installer
embeds before limine-entry-tool pins the UKI's hash, building a UKI only for
an image with no room.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.path.insert(0, str(Path(__file__).parent))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402
from orchestrator.uki_vconsole import NON_LATIN_LAYOUTS, ROOM, embed_vconsole, placeholder, vconsole_fits  # noqa: E402
from test_uki_cmdline import with_room as uki_with_cmdline_room  # noqa: E402

BUILD = ROOT / "builder/build-root-image.sh"
BEFORE, AFTER = b"EARLY-CPIO-HEADER" * 3, b"\0" * 7 + b"ZSTD-MAIN-IMAGE" * 9
UK = 'KEYMAP=uk\nXKBLAYOUT=gb\nXKBMODEL=pc105\nFONT=ter-v32b\n'


def build_snippet(pattern: str) -> str:
    """The lines of build-root-image.sh from the one matching pattern to the
    next blank line."""
    lines = BUILD.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if pattern in line)
    end = next(i for i in range(start, len(lines)) if not lines[i].strip())
    return "\n".join(lines[start:end])


class EmbedVconsoleTest(unittest.TestCase):
    def setUp(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.uki, self.vconsole = directory / "uki.efi", directory / "vconsole.conf"
        self.uki.write_bytes(BEFORE + placeholder() + AFTER)
        self.vconsole.write_text(UK)

    def test_the_room_is_one_comment_line(self):
        room = placeholder()
        self.assertEqual(len(room), ROOM)
        self.assertEqual(room.count(b"\n"), 1)
        self.assertTrue(room.startswith(b"#") and room.endswith(b"\n"))

    def test_the_keyboard_settings_are_written_in_place(self):
        self.assertTrue(vconsole_fits(self.uki, self.vconsole))
        self.assertTrue(embed_vconsole(self.uki, self.vconsole))
        image = self.uki.read_bytes()
        self.assertEqual(len(image), len(BEFORE) + ROOM + len(AFTER), "the image changed size")
        self.assertTrue(image.startswith(BEFORE) and image.endswith(AFTER), "bytes around the room were touched")
        written = image[len(BEFORE):len(BEFORE) + ROOM].decode()
        self.assertTrue(written.startswith("KEYMAP=uk\nXKBLAYOUT=gb\nXKBMODEL=pc105\n#"))
        self.assertTrue(written.endswith("#\n"))
        # What systemd-vconsole-setup and Plymouth will read from it.
        settings = [line for line in written.splitlines() if not line.startswith("#")]
        self.assertEqual(settings, ["KEYMAP=uk", "XKBLAYOUT=gb", "XKBMODEL=pc105"], "a FONT names a file this initramfs lacks")

    def test_settings_that_do_not_fit_are_refused(self):
        self.vconsole.write_text("KEYMAP=uk\nXKBOPTIONS=" + "x" * ROOM + "\n")
        before = self.uki.read_bytes()
        self.assertFalse(vconsole_fits(self.uki, self.vconsole))
        self.assertFalse(embed_vconsole(self.uki, self.vconsole))
        self.assertEqual(self.uki.read_bytes(), before)

    def test_no_settings_or_no_file_is_refused(self):
        before = self.uki.read_bytes()
        for text in ("FONT=ter-v32b\n", "# KEYMAP=uk\n", None):
            with self.subTest(text=text):
                self.vconsole.unlink(missing_ok=True)
                if text is not None:
                    self.vconsole.write_text(text)
                self.assertFalse(vconsole_fits(self.uki, self.vconsole))
                self.assertFalse(embed_vconsole(self.uki, self.vconsole))
                self.assertEqual(self.uki.read_bytes(), before)

    def test_a_uki_without_the_room_or_with_two_is_left_alone(self):
        for image in (BEFORE + AFTER, BEFORE + placeholder()[:-2] + AFTER, placeholder() + BEFORE + placeholder(), b""):
            with self.subTest(size=len(image)):
                self.uki.write_bytes(image)
                self.assertFalse(vconsole_fits(self.uki, self.vconsole))
                self.assertFalse(embed_vconsole(self.uki, self.vconsole))
                self.assertEqual(self.uki.read_bytes(), image)

    def test_nonlatin_layouts_are_refused_so_the_prompt_stays_us(self):
        before = self.uki.read_bytes()
        for text in (
            "KEYMAP=ua\nXKBLAYOUT=ua,us\nXKBMODEL=pc105\n",
            "KEYMAP=bg-cp1251\nXKBLAYOUT=bg,us\nXKBVARIANT=phonetic,\n",
            "KEYMAP=kyrgyz\nXKBLAYOUT=kg,us\n",
            "KEYMAP=ru\nXKBLAYOUT=ru,us\n",
            "KEYMAP=sr-cy\nXKBLAYOUT=rs\n",
        ):
            with self.subTest(text=text):
                self.vconsole.write_text(text)
                self.assertFalse(vconsole_fits(self.uki, self.vconsole))
                self.assertFalse(embed_vconsole(self.uki, self.vconsole))
                self.assertEqual(self.uki.read_bytes(), before)

    def test_serbian_latin_and_multilayout_latin_settings_are_embedded(self):
        cases = (
            (
                "KEYMAP=sr-latin\nXKBLAYOUT=rs\nXKBMODEL=pc105\nXKBVARIANT=latin\n",
                ["KEYMAP=sr-latin", "XKBLAYOUT=rs", "XKBMODEL=pc105", "XKBVARIANT=latin"],
            ),
            (
                "KEYMAP=cz\nXKBLAYOUT=cz,us\nXKBMODEL=pc105\nXKBVARIANT=qwerty,\n"
                "XKBOPTIONS=terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll\n",
                [
                    "KEYMAP=cz",
                    "XKBLAYOUT=cz,us",
                    "XKBMODEL=pc105",
                    "XKBVARIANT=qwerty,",
                    "XKBOPTIONS=terminate:ctrl_alt_bksp,grp:shifts_toggle,grp_led:scroll",
                ],
            ),
        )
        for text, expected in cases:
            with self.subTest(expected=expected[0]):
                self.uki.write_bytes(BEFORE + placeholder() + AFTER)
                self.vconsole.write_text(text)
                self.assertTrue(vconsole_fits(self.uki, self.vconsole))
                self.assertTrue(embed_vconsole(self.uki, self.vconsole))
                written = self.uki.read_bytes()[len(BEFORE):len(BEFORE) + ROOM].decode()
                settings = [line for line in written.splitlines() if not line.startswith("#")]
                self.assertEqual(settings, expected)

    def test_nonlatin_layout_list_matches_omarchy_hooks_conf(self):
        candidates = (
            Path(os.environ.get("OMARCHY_PATH") or "/nonexistent") / "etc/mkinitcpio.conf.d/omarchy_hooks.conf",
            Path("/omarchy-source/etc/mkinitcpio.conf.d/omarchy_hooks.conf"),
            ROOT.parent / "omarchy/etc/mkinitcpio.conf.d/omarchy_hooks.conf",
        )
        hooks_conf = next((p for p in candidates if p.is_file()), None)
        if hooks_conf is None:
            self.skipTest("no Omarchy runtime checkout to compare NON_LATIN_LAYOUTS against")
        match = re.search(r'case \$\(\. /etc/vconsole\.conf && echo "\$\{XKBLAYOUT%%,\*\}"\) in\s*\n\s*([^)]+)\)', hooks_conf.read_text())
        self.assertIsNotNone(match, f"could not parse non-Latin layout list from {hooks_conf}")
        expected = frozenset(part.strip() for part in match.group(1).split("|"))
        self.assertEqual(NON_LATIN_LAYOUTS, expected)

    def test_a_second_embed_finds_no_room(self):
        self.assertTrue(embed_vconsole(self.uki, self.vconsole))
        written = self.uki.read_bytes()
        self.assertFalse(embed_vconsole(self.uki, self.vconsole))
        self.assertEqual(self.uki.read_bytes(), written)


class ImageBuildTest(unittest.TestCase):
    def test_the_build_reserves_exactly_the_room_the_installer_looks_for(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / "etc").mkdir()
            subprocess.run(["bash", "-c", build_snippet('vconsole_room="')], env={**os.environ, "root": root}, check=True)
            self.assertEqual((Path(root) / "etc/vconsole.conf.prebuilt-uki").read_bytes(), placeholder())

    def test_the_initramfs_gets_the_room_and_every_keymap_and_the_image_keeps_neither_file(self):
        build = BUILD.read_text()
        hook = build_snippet("omarchy-vconsole-room\" <<'INSTALL'")
        self.assertIn("add_full_dir /usr/share/kbd/keymaps", hook)
        self.assertIn("add_file_early /etc/vconsole.conf.prebuilt-uki /etc/vconsole.conf", hook)
        self.assertRegex(build, r"HOOKS=\(.* sd-vconsole omarchy-vconsole-room .*\)")
        cleanup = build[build.index("# Only this build uses these"):]
        for left in ("/etc/vconsole.conf.prebuilt-uki", "/usr/lib/initcpio/install/omarchy-vconsole-room"):
            self.assertIn(f'"$root{left}"', cleanup[:cleanup.index("fi\n")])

    @unittest.skipUnless(shutil.which("mkinitcpio") and shutil.which("lsinitcpio"), "mkinitcpio is not installed")
    def test_mkinitcpio_keeps_the_room_where_the_installer_can_write_it(self):
        """The build's own hook, run by the real mkinitcpio: the reserved file
        must sit in the image uncompressed, exactly once, and what is written
        there must be what the initramfs unpacks as /etc/vconsole.conf."""
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        room = directory / "vconsole.conf.prebuilt-uki"
        room.write_bytes(placeholder())
        hooks = directory / "hooks/install"
        hooks.mkdir(parents=True)
        # The hook between its heredoc lines, with the image's path for the room.
        hook = build_snippet("omarchy-vconsole-room\" <<'INSTALL'").split("\n", 1)[1].rsplit("\nINSTALL", 1)[0]
        (hooks / "omarchy-vconsole-room").write_text(hook.replace("/etc/vconsole.conf.prebuilt-uki", str(room)))
        (directory / "conf").write_text('MODULES=()\nBINARIES=()\nFILES=()\nHOOKS=(omarchy-vconsole-room)\nCOMPRESSION="zstd"\n')
        image = directory / "initramfs.img"
        built = subprocess.run(
            ["mkinitcpio", "-c", str(directory / "conf"), "-D", str(directory / "hooks"), "-D", "/usr/lib/initcpio",
             "-k", "none", "-g", str(image)], capture_output=True, text=True)
        self.assertTrue(image.is_file(), f"mkinitcpio built no image with the hook: {built.stdout[-400:]}{built.stderr[-400:]}")
        self.assertEqual(image.read_bytes().count(placeholder()), 1, "the room is not in the image as written")

        vconsole = directory / "vconsole.conf"
        vconsole.write_text(UK)
        self.assertTrue(embed_vconsole(image, vconsole))
        unpacked = directory / "unpacked"
        unpacked.mkdir()
        subprocess.run(["lsinitcpio", "-x", str(image)], cwd=unpacked, check=True, capture_output=True)
        settings = [line for line in (unpacked / "etc/vconsole.conf").read_text().splitlines() if not line.startswith("#")]
        self.assertEqual(settings, ["KEYMAP=uk", "XKBLAYOUT=gb", "XKBMODEL=pc105"])
        self.assertTrue(list(unpacked.glob("usr/share/kbd/keymaps/**/uk.map*")), "the uk keymap is not in the initramfs")
        self.assertTrue(list(unpacked.glob("usr/share/kbd/keymaps/**/de-latin1.map*")), "not every keymap is in the initramfs")


class InstallTest(unittest.TestCase):
    """finalize_limine_boot on a target that picked uk."""

    def install(self, uki: bytes, vconsole: str = UK):
        target = Path(self.enterContext(tempfile.TemporaryDirectory()))
        for path, text in {
            "usr/bin/limine-update": "",
            "etc/default/limine": 'ESP_PATH="/boot"\nCUSTOM_UKI_NAME="omarchy"\nKERNEL_CMDLINE[default]+="root=UUID=x rw"\n',
            "etc/snapper/configs/root": "",
            "boot/limine.conf": "/+Omarchy\n",
            "var/lib/omarchy-iso/prebuilt-uki.kernel": "linux-omarchy\n",
            "var/lib/omarchy-iso/prebuilt-uki.keymap": "\n",
            "etc/vconsole.conf": vconsole,
        }.items():
            (target / path).parent.mkdir(parents=True, exist_ok=True)
            (target / path).write_text(text)
        (target / "var/lib/omarchy-iso/prebuilt-uki.efi").write_bytes(uki)
        esp_uki = target / "boot/EFI/Linux/omarchy_linux-omarchy.efi"
        ran, hashed = [], []

        def run(cmd, **_kwargs):
            ran.append(" ".join(map(str, cmd)))
            if "--add-uki" in cmd:
                hashed.append(esp_uki.read_bytes())
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        ctx = types.SimpleNamespace(target=target, user_configuration={"kernels": ["linux-omarchy"]})
        with mock.patch.object(phases_impl.subprocess, "run", run), \
             mock.patch.object(phases_impl, "arch", types.SimpleNamespace(has_uefi=lambda: True)), \
             mock.patch.object(phases_impl, "info", lambda *_: None), \
             mock.patch.object(phases_impl, "_is_apple_t2_hardware", lambda: False):
            phases_impl.finalize_limine_boot(ctx)
        return ran, hashed

    def test_an_image_with_room_takes_the_layout_and_builds_nothing(self):
        ran, hashed = self.install(uki_with_cmdline_room() + placeholder())
        self.assertFalse([cmd for cmd in ran if "limine-mkinitcpio" in cmd], "a UKI was built on the target")
        self.assertEqual(len(hashed), 1, "limine-entry-tool --add-uki did not run once")
        self.assertIn(b"KEYMAP=uk\nXKBLAYOUT=gb\n", hashed[0], "the layout was not in the UKI when Limine hashed it")
        self.assertNotIn(placeholder(), hashed[0])

    def test_an_image_without_room_builds_its_uki_on_the_target(self):
        ran, hashed = self.install(uki_with_cmdline_room())
        self.assertTrue([cmd for cmd in ran if cmd.endswith("limine-mkinitcpio")], "no UKI was built for the layout")
        self.assertEqual(hashed, [])

    def test_a_nonlatin_layout_keeps_the_prebuilt_uki_on_us(self):
        ran, hashed = self.install(
            uki_with_cmdline_room() + placeholder(),
            vconsole="KEYMAP=ua\nXKBLAYOUT=ua,us\nXKBMODEL=pc105\n",
        )
        self.assertFalse([cmd for cmd in ran if "limine-mkinitcpio" in cmd], "a UKI was built for a non-Latin layout")
        self.assertEqual(len(hashed), 1)
        self.assertIn(placeholder(), hashed[0], "the placeholder was overwritten with a non-Latin layout")
        self.assertNotIn(b"XKBLAYOUT=ua", hashed[0])


if __name__ == "__main__":
    unittest.main()
