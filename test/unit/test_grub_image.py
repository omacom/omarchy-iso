"""The x86_64 EFI images' GRUB (builder/grub/grub-mkstandalone).

mkarchiso's images carry every GRUB module and the Unicode font; the wrapper
gives them the modules mkarchiso names, their dependencies and what the boot
configs use besides, and the menu's own font. Missing a module only shows at
boot, and quietly: without test every [ ... ] is false, without smbios a Mac
boots the wrong kernel. So these cases check:

- the wrapper's arguments for the x86_64 and IA32 images, and that it leaves
  every other target as mkarchiso built it;
- every command configs/grub/*.cfg and mkarchiso's embedded config run has its
  module in the image (where GRUB's x86_64-efi modules and mkarchiso are
  installed, or OMARCHY_GRUB_MODULES and OMARCHY_MKARCHISO point at them);
- the menu font: the glyphs the menu can show, each as Unifont draws it, and
  what bin/omarchy-grub-menu-font writes from GRUB's unicode.pf2 now (where
  that is installed, or OMARCHY_UNICODE_PF2 points at it).
"""

import importlib.util
import os
import re
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "builder/grub/grub-mkstandalone"
FONT = ROOT / "builder/grub/menu.pf2"
GRUB_CONFIGS = [ROOT / "configs/grub/grub.cfg", ROOT / "configs/grub/loopback.cfg"]
GRUB_MODULES = Path(os.environ.get("OMARCHY_GRUB_MODULES", "/usr/lib/grub/x86_64-efi"))
UNICODE_PF2 = Path(os.environ.get("OMARCHY_UNICODE_PF2", "/usr/share/grub/unicode.pf2"))
MKARCHISO = next((path for path in (Path(os.environ.get("OMARCHY_MKARCHISO", "/nonexistent")),
                                    ROOT / "archiso/archiso/mkarchiso", Path("/usr/bin/mkarchiso")) if path.is_file()), None)

loader = SourceFileLoader("omarchy_grub_menu_font", str(ROOT / "bin/omarchy-grub-menu-font"))
spec = importlib.util.spec_from_loader("omarchy_grub_menu_font", loader)
menu_font = importlib.util.module_from_spec(spec)
loader.exec_module(menu_font)


def wrapper_args(*args):
    """What the wrapper hands grub-mkstandalone, one argument a line."""
    with tempfile.TemporaryDirectory() as work:
        stub = Path(work) / "grub-mkstandalone"
        stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
        stub.chmod(0o755)
        env = {**os.environ, "OMARCHY_GRUB_MKSTANDALONE": str(stub)}
        return subprocess.run([str(WRAPPER), *args], env=env, capture_output=True, text=True, check=True).stdout.splitlines()


def mkarchiso_modules():
    """The modules mkarchiso builds its x86_64 images with (its first non-empty list)."""
    lists = re.findall(r"grubmodules=\(([^)]+)\)", MKARCHISO.read_text())
    return lists[0].replace("\\", " ").split()


def embedded_config():
    text = MKARCHISO.read_text()
    match = re.search(r"grubembedcfg <<'EOF' \|\| true\n(.*?)\nEOF\n", text, re.S)
    return match.group(1) if match else ""


def commands(config):
    """The first word of each command in a GRUB script."""
    words = set()
    for line in config.splitlines():
        line = line.split("#", 1)[0] if not line.lstrip().startswith("menuentry") else line
        for part in re.split(r"[;{}]", line):
            tokens = part.split()
            while tokens and tokens[0] in ("if", "elif", "then", "else", "while", "do", "!"):
                tokens = tokens[1:]
            if tokens and tokens[0] not in ("fi", "done"):
                words.add(tokens[0])
    return words


class WrapperTest(unittest.TestCase):
    MODULES = "--modules=fat iso9660 linux normal"

    def test_the_x86_64_and_ia32_images_get_their_modules_and_the_menu_font(self):
        for target in ("x86_64-efi", "i386-efi"):
            with self.subTest(target=target):
                args = wrapper_args("-O", target, self.MODULES, "-o", "BOOTx64.EFI", "boot/grub/grub.cfg=embed.cfg")
                self.assertEqual(args[:6], ["-O", target, self.MODULES, "-o", "BOOTx64.EFI", "boot/grub/grub.cfg=embed.cfg"])
                self.assertIn("--install-modules=fat iso9660 linux normal test probe smbios", args)
                self.assertIn("--fonts=", args)
                self.assertIn(f"boot/grub/fonts/menu.pf2={FONT}", args)

    def test_other_targets_as_mkarchiso_builds_them(self):
        for args in (("-O", "arm64-efi", self.MODULES, "-o", "BOOTAA64.EFI"), ("-O", "x86_64-efi", "-o", "x.efi")):
            with self.subTest(args=args):
                self.assertEqual(wrapper_args(*args), list(args))


@unittest.skipUnless((GRUB_MODULES / "command.lst").is_file() and MKARCHISO, "GRUB's x86_64-efi modules or mkarchiso missing")
class CommandTest(unittest.TestCase):
    def test_every_command_the_boot_runs_is_in_the_image(self):
        command_module = {}
        for line in (GRUB_MODULES / "command.lst").read_text().splitlines():
            name, module = line.split(": ")
            command_module[name.lstrip("*")] = module
        depends = {}
        for line in (GRUB_MODULES / "moddep.lst").read_text().splitlines():
            module, _, rest = line.partition(":")
            depends[module] = rest.split()
        extra = re.search(r'^extra_modules="([^"]*)"', WRAPPER.read_text(), re.M).group(1).split()
        image, todo = set(), mkarchiso_modules() + extra
        while todo:
            module = todo.pop()
            if module not in image:
                image.add(module)
                todo += depends.get(module, [])
        scripts = {path.name: path.read_text() for path in GRUB_CONFIGS}
        scripts["the embedded config"] = embedded_config()
        self.assertTrue(scripts["the embedded config"], "mkarchiso's embedded config not found")
        for name, script in scripts.items():
            used = {(word, command_module[word]) for word in commands(script) if word in command_module}
            inserted = set(re.findall(r"insmod\s+([a-z0-9_]+)", script))
            with self.subTest(config=name):
                self.assertEqual(sorted((w, m) for w, m in used if m not in image), [])
                self.assertEqual(sorted(inserted - image), [])


class FontTest(unittest.TestCase):
    def test_the_glyphs_a_menu_can_show(self):
        glyphs = menu_font.glyphs(FONT.read_bytes())
        for code in [*range(0x20, 0x7F), 0x2191, 0x2193, 0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518]:
            self.assertIn(code, glyphs, f"U+{code:04X}")
        self.assertTrue(all(menu_font.in_ranges(code) for code in glyphs))

    @unittest.skipUnless(UNICODE_PF2.is_file(), "GRUB's unicode.pf2 is not installed")
    def test_as_the_generator_writes_it_from_unifont(self):
        source = UNICODE_PF2.read_bytes()
        unifont = menu_font.glyphs(source)
        for code, (_, entry) in menu_font.glyphs(FONT.read_bytes()).items():
            self.assertEqual(entry, unifont[code][1], f"U+{code:04X}")
        self.assertEqual(menu_font.subset(source, menu_font.in_ranges), FONT.read_bytes())


if __name__ == "__main__":
    unittest.main()
