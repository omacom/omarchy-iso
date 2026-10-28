"""Unit tests for the boot menus: what they offer and how they look.

The x86_64 menus offer Install and Try and nothing else, in GRUB (UEFI, and an
ISO file booted through loopback.cfg) and in syslinux (BIOS), with the same
countdown. The GRUB theme refers only to files builder/boot-menu-theme.sh
makes and fonts grub.cfg loads, and its entries keep enough contrast for a
person to read them and for test/integration.d's OCR to find them.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GRUB = ROOT / "configs/grub"
SYSLINUX = ROOT / "configs/syslinux"
THEME = GRUB / "themes/omarchy/theme.txt"
THEME_CFG = GRUB / "theme.cfg"
THEME_BUILDER = ROOT / "builder/boot-menu-theme.sh"


def configured(name, arch):
    """A GRUB config as builder/build-iso.sh leaves it for one architecture."""
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / name
        shutil.copy(GRUB / name, config)
        subprocess.run(
            ["bash", "-c", 'source "$1" && configure_grub_platform "$2" "$3"', "_",
             ROOT / "builder/grub-platform.sh", config, arch],
            check=True,
        )
        return config.read_text()


def entries(config):
    return re.findall(r'^\s*menuentry\s+["\']([^"\']+)["\']', config, re.M)


def luminance(hex_color):
    channels = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


class MenuEntries(unittest.TestCase):
    def test_uefi_menu_offers_install_and_try(self):
        config = configured("grub.cfg", "x86_64")
        # The device-tree entry is inside `if grub_cpu == arm64`.
        self.assertEqual(
            [e for e in entries(config) if "device tree" not in e],
            ["Install Omarchy", "Try Omarchy"],
        )

    def test_iso_file_menu_offers_install_and_try(self):
        self.assertEqual(entries(configured("loopback.cfg", "x86_64")), ["Install Omarchy", "Try Omarchy"])

    def test_aarch64_keeps_its_own_entries(self):
        config = configured("grub.cfg", "aarch64")
        self.assertIn("N1x recovery shell (hardware probe, no installer)", entries(config))
        self.assertIn("Omarchy (aarch64, ${archiso_platform}, device tree)",
                      [e.replace("%ARCH%", "aarch64") for e in entries(config)])

    def test_bios_menu_offers_install_and_try(self):
        labels = []
        for cfg in ("archiso_sys.cfg", "archiso_sys-linux.cfg", "archiso_head.cfg"):
            labels += re.findall(r"^MENU LABEL (.+)$", (SYSLINUX / cfg).read_text(), re.M)
        # A caret marks an entry's hotkey: T for Try, as before.
        self.assertEqual(labels, ["Install Omarchy", "^Try Omarchy"])
        self.assertFalse((SYSLINUX / "archiso_tail.cfg").exists())

    def test_bios_entries_fit_the_menu(self):
        head = (SYSLINUX / "archiso_head.cfg").read_text()
        width = int(re.search(r"^MENU WIDTH (\d+)$", head, re.M).group(1))
        margin = int(re.search(r"^MENU MARGIN (\d+)$", head, re.M).group(1))
        labels = []
        for cfg in ("archiso_sys-linux.cfg", "archiso_pxe-linux.cfg"):
            labels += re.findall(r"^MENU LABEL (.+)$", (SYSLINUX / cfg).read_text(), re.M)
        # menumain.c gives an entry width - 2 * margin - 4 columns; the PXE
        # test finds its entry by "NBD".
        for label in labels:
            self.assertLessEqual(len(label.replace("^", "")), width - 2 * margin - 4, label)

    def test_bios_command_line_stays_on_screen(self):
        head = (SYSLINUX / "archiso_head.cfg").read_text()
        row = {key: int(re.search(rf"^MENU {key} (\d+)$", head, re.M).group(1))
               for key in ("VSHIFT", "CMDLINEROW", "TABMSGROW", "HELPMSGROW", "HELPMSGENDROW")}
        # vesamenu at 640x480 has 30 rows. menumain.c adds VSHIFT to the
        # command line, tab message and help start rows, not to the help end.
        for key in ("CMDLINEROW", "TABMSGROW", "HELPMSGROW"):
            self.assertLess(row[key] + row["VSHIFT"], 30, key)
        self.assertLess(row["HELPMSGENDROW"], 30)
        self.assertGreaterEqual(row["HELPMSGENDROW"], row["HELPMSGROW"] + row["VSHIFT"])

    def test_bios_and_uefi_count_down_alike(self):
        grub_timeout = re.search(r"^timeout=(\d+)$", configured("grub.cfg", "x86_64"), re.M)
        bios_timeout = re.search(r"^TIMEOUT (\d+)$", (SYSLINUX / "archiso_sys.cfg").read_text(), re.M)
        # syslinux counts tenths of a second.
        self.assertEqual(int(bios_timeout.group(1)), int(grub_timeout.group(1)) * 10)


class Theme(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.theme = THEME.read_text()
        cls.builder = THEME_BUILDER.read_text()

    def test_every_file_the_theme_names_is_built(self):
        files = re.findall(r'file = "([^"]+)"', self.theme)
        styles = re.findall(r'(?:_style|_frame|_thumb|terminal-box)\s*[:=]\s*"([^"*]+)\*\.png"', self.theme)
        self.assertTrue(files and styles)
        for name in files + [s + "c.png" for s in styles]:
            stem = name.replace(".png", "")
            self.assertTrue(name in self.builder or f"{stem.rsplit('_', 1)[0]}_$part.png" in self.builder
                            or f'"$theme_dir/{name}"' in self.builder, f"{name} is not built")

    def test_pixmaps_are_truecolor(self):
        # A one-colour picture from ImageMagick is a 1-bit colormap PNG by
        # default; GRUB cannot read that, and the selection bar vanished.
        outputs = re.findall(r'^\s*magick .*?(\S+)(?: \|\| return 1)?$', self.builder, re.M)
        self.assertTrue(outputs)
        for output in outputs:
            self.assertRegex(output, r"^PNG(24|32):", output)

    def test_every_font_the_theme_names_is_built_and_loaded(self):
        theme_cfg = THEME_CFG.read_text()
        for family, weight, size in re.findall(r'"(JetBrains Mono) (Regular|Bold) (\d+)"', self.theme):
            font = f"jetbrains-mono-{weight.lower()}-{size}"
            self.assertRegex(theme_cfg, rf"for font in [\w -]*\b{font}\b", f"{font} is not loaded")
            self.assertRegex(self.builder, rf"for size in [\d ]*\b{size}\b", f"{font} is not built")

    def test_the_menu_holds_both_entries(self):
        menu = self.theme[self.theme.index("+ boot_menu"):]
        value = lambda key: int(re.search(rf"\b{key} = (\d+)\b", menu).group(1))
        # Install and Try, with no scrolling at any resolution. GRUB's list takes
        # the selection box's edges (select_n/select_s, 1 px each, built by
        # builder/boot-menu-theme.sh) off its height before it counts rows.
        edges = 2
        self.assertIn('for part in n ne e se s sw c; do\n    magick -size 1x1', self.builder)
        self.assertEqual(value("height"), 2 * value("item_height") + value("item_spacing") + edges)

    def test_entries_are_readable(self):
        background = re.search(r'desktop-color: "(#[0-9a-f]{6})"', self.theme).group(1)
        for key in ("item_color", "selected_item_color"):
            color = re.search(rf'\b{key} = "(#[0-9a-f]{{6}})"', self.theme).group(1)
            # WCAG AA for text. Tokyo Night's dark foreground (#565f89, 2.8:1)
            # vanished from the harness's thresholded OCR, so try-test could
            # not find "Try Omarchy".
            self.assertGreaterEqual(contrast(color, background), 4.5, f"{key} {color} on {background}")

    def test_both_menus_load_the_theme(self):
        # A stick boots grub.cfg; an ISO file booted by another GRUB (Ventoy's
        # GRUB2 mode, a grub.cfg with loopback) boots loopback.cfg.
        for cfg in ("grub.cfg", "loopback.cfg"):
            self.assertRegex((GRUB / cfg).read_text(), r"(?m)^\s*source /boot/grub/theme\.cfg$", cfg)

    def test_the_theme_is_set_only_with_its_fonts(self):
        theme_cfg = THEME_CFG.read_text()
        # Only media that carry it (x86_64), and only when every font loads:
        # a signed GRUB under Secure Boot refuses unsigned fonts, and the menu
        # then keeps the look it has rather than a theme without its fonts.
        self.assertIn('if [ -f "$omarchy_theme/theme.txt" ]; then', theme_cfg)
        self.assertRegex(theme_cfg, r'if ! loadfont "\$omarchy_theme/\$font\.pf2"; then\s+omarchy_theme=')
        set_at = theme_cfg.index('set theme="$omarchy_theme/theme.txt"')
        self.assertLess(theme_cfg.index('if [ -n "$omarchy_theme" ]; then'), set_at)
        self.assertIn("export theme", theme_cfg[set_at:])


if __name__ == "__main__":
    unittest.main()
