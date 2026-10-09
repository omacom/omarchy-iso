import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "builder/check-arm-packages.sh"
BOOT_FILES = (
    "etc/mkinitcpio.conf.d/omarchy_hooks.conf",
    "etc/limine-entry-tool.d/omarchy-defaults.conf",
    "etc/limine-entry-tool.d/omarchy-uki.conf",
    "usr/share/omarchy/default/limine/limine.conf",
)
PACMAN_FILES = (
    "usr/share/omarchy/default/pacman/pacman-aarch64.conf",
    "usr/share/omarchy/default/pacman/mirrorlist-aarch64",
)
RUNTIME_FILES = tuple(
    f"usr/share/omarchy/install/hardware/qualcomm/{name}.sh"
    for name in ("dtb-uki", "firmware", "kernel-params")
)


class ArmPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.package("omarchy", RUNTIME_FILES)
        self.settings = self.package("omarchy-settings", BOOT_FILES + PACMAN_FILES)

    def package(self, name, files, version="1", prefix=""):
        path = self.root / f"{name}-{version}-aarch64.pkg.tar.xz"
        with tarfile.open(path, "w:xz") as archive:
            for entry in (".PKGINFO", *files):
                data = f"pkgname = {name}\npkgver = {version}\n".encode() if entry == ".PKGINFO" else b"fixture\n"
                info = tarfile.TarInfo(prefix + entry)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def check(self, target="aarch64/snapdragon"):
        return subprocess.run(
            ["bash", str(CHECKER), target, str(self.runtime), str(self.settings)],
            text=True, capture_output=True,
        )

    def test_complete_packages_pass_with_both_archive_path_styles(self):
        for prefix in ("", "./"):
            with self.subTest(prefix=prefix):
                self.runtime = self.package("omarchy-dev", RUNTIME_FILES, prefix=prefix)
                self.settings = self.package("omarchy-settings-dev", BOOT_FILES + PACMAN_FILES, prefix=prefix)
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_missing_required_file_fails_with_actionable_error(self):
        for missing in (*BOOT_FILES, *PACMAN_FILES, *RUNTIME_FILES):
            with self.subTest(missing=missing):
                self.runtime = self.package("omarchy", [p for p in RUNTIME_FILES if p != missing])
                self.settings = self.package("omarchy-settings", [p for p in BOOT_FILES + PACMAN_FILES if p != missing])
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)
                self.assertIn("selected channel", result.stderr)

    def test_generic_requires_boot_settings_but_not_snapdragon_scripts(self):
        self.runtime = self.package("omarchy", ())
        self.settings = self.package("omarchy-settings", BOOT_FILES)
        result = self.check("aarch64/generic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.settings = self.package("omarchy-settings", ())
        self.assertNotEqual(self.check("aarch64/generic").returncode, 0)

    def test_corrupt_archive_and_unknown_target_fail(self):
        self.assertNotEqual(self.check("aarch64/unknown").returncode, 0)
        for package in (self.runtime, self.settings):
            with self.subTest(package=package):
                original = package.read_bytes()
                package.write_bytes(b"not a package")
                self.assertNotEqual(self.check().returncode, 0)
                package.write_bytes(original)

    def test_offline_selection_uses_exact_metadata_and_rejects_duplicates(self):
        builder = (ROOT / "builder/build-iso.sh").read_text()
        function = re.search(r"^find_offline_package\(\) \{\n.*?^\}", builder, re.M | re.S).group()
        tools = self.root / "tools"
        tools.mkdir()
        pacman = tools / "pacman"
        pacman.write_text('#!/bin/bash\n[[ $1 == -Qp ]] || exit 1\nbsdtar -xOf "$2" .PKGINFO | sed -n "s/^pkgname = / /p"\n')
        pacman.chmod(0o755)
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")

        def select(name):
            return subprocess.run(
                ["bash", "-c", function + '\noffline_mirror_dir=$1\nfind_offline_package "$2"',
                 "test", str(self.root), name], env=env, text=True, capture_output=True,
            )

        self.package("omarchy-dev", RUNTIME_FILES)
        result = select("omarchy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.runtime))
        self.assertNotEqual(select("missing").returncode, 0)
        self.package("omarchy", RUNTIME_FILES, version="2")
        self.assertNotEqual(select("omarchy").returncode, 0)

    def test_builder_checks_selected_packages_after_cache_pruning(self):
        builder = (ROOT / "builder/build-iso.sh").read_text()
        check = builder.index('bash /builder/check-arm-packages.sh "$OMARCHY_MEDIA_TARGET" "$runtime_package" "$settings_package"')
        self.assertLess(builder.index("bash /builder/prune-offline-mirror.sh"), check)
        self.assertLess(check, builder.index('bash /builder/index-offline-mirror.sh "$offline_mirror_dir"'))
