"""Exercise the real launcher without Docker, sudo or host cache writes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IsoArchitectureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("bin/omarchy-iso-make", "builder/architecture.sh", "configs/profiledef.sh"):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        HOME=str(self.root / "home"), TEST_ROOT=str(self.root),
                        TEST_MACHINE="arm64", TEST_OS="Darwin")
        for name in ("OMARCHY_ARCH", "OMARCHY_MEDIA_TARGET", "OMARCHY_ISO_NAME", "OMARCHY_MIRROR"):
            self.env.pop(name, None)
        self.stub("uname", '#!/bin/bash\nif [[ $1 == -m ]]; then echo "$TEST_MACHINE"; else echo "$TEST_OS"; fi\n')
        self.stub("sudo", '#!/bin/bash\necho "Unexpected sudo" >&2\nexit 99\n')
        self.stub("git", '#!/bin/bash\nexit 0\n')
        self.stub("docker", '''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == "version":
    sys.exit(0)
root = pathlib.Path(os.environ["TEST_ROOT"])
(root / "docker.json").write_text(json.dumps(sys.argv[1:]))
args = dict(arg.split("=", 1) for arg in sys.argv[1:] if arg.startswith("OMARCHY_"))
arch = args["OMARCHY_ARCH"]
name = "omarchy-generic" if args["OMARCHY_MEDIA_TARGET"] == "aarch64/generic" else "omarchy"
(root / "release" / f"{name}-2026.09.10-{arch}.iso").write_bytes(b"test ISO")
''')

    def stub(self, name, script):
        executable = self.tools / name
        executable.write_text(script)
        executable.chmod(0o755)

    def launch(self, *args):
        return subprocess.run(["bash", str(self.root / "bin/omarchy-iso-make"),
                               "--keep-pkg-cache", "--no-boot-offer", "--edge", *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_published_channels_select_the_matching_mirror_without_local_packages(self):
        for options, mirror, ref in (((), "stable", "quattro"),
                                     (("--edge",), "edge", "edge"),
                                     (("--rc",), "rc", "rc")):
            with self.subTest(mirror=mirror):
                result = subprocess.run(
                    ["bash", str(self.root / "bin/omarchy-iso-make"),
                     "--keep-pkg-cache", "--no-boot-offer", "--arch", "aarch64",
                     "--media-target", "aarch64/snapdragon", *options],
                    cwd=self.root, env=self.env, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads((self.root / "docker.json").read_text())
                self.assertIn(f"OMARCHY_MIRROR={mirror}", args)
                self.assertIn(f"OMARCHY_ISO_REF={ref}", args)
                self.assertFalse(any(":/omarchy-repo:" in arg for arg in args))
                self.assertFalse(any(":/omarchy-source:" in arg for arg in args))

    def test_defaults_and_explicit_targets_select_image_platform_and_isolated_cache(self):
        cases = [
            ("arm64", (), "aarch64", "snapdragon", "linux/arm64", "menci/archlinuxarm:base-devel"),
            ("x86_64", (), "x86_64", "pc", "linux/amd64", "archlinux/archlinux:latest"),
            ("x86_64", ("--arch", "aarch64", "--media-target", "aarch64/generic"),
             "aarch64", "generic", "linux/arm64", "menci/archlinuxarm:base-devel"),
        ]
        for machine, options, arch, target, docker_platform, image in cases:
            with self.subTest(target=target):
                self.env["TEST_MACHINE"] = machine
                result = self.launch(*options)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads((self.root / "docker.json").read_text())
                self.assertEqual(args[args.index("--platform") + 1], docker_platform)
                self.assertIn(image, args)
                self.assertIn(f"OMARCHY_ARCH={arch}", args)
                self.assertIn(f"OMARCHY_MEDIA_TARGET={arch}/{target}", args)
                cache = self.root / f"home/.cache/omarchy/iso_edge/{arch}/{target}/airootfs/var/cache/omarchy"
                self.assertIn(f"{cache}:/var/cache/airootfs/var/cache/omarchy", args)
                name = "omarchy-generic" if target == "generic" else "omarchy"
                self.assertTrue((self.root / f"release/{name}-2026.09.10-{arch}-edge.iso").exists())

    def test_invalid_selection_fails_before_side_effects(self):
        cases = [("--arch",), ("--arch", "--edge"), ("--arch", "riscv64"),
                 ("--arch", "x86_64", "--media-target", "aarch64/generic"),
                 ("--media-target", "aarch64/unknown")]
        for args in cases:
            with self.subTest(args=args):
                result = self.launch(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "docker.json").exists())
                self.assertFalse((self.root / "release").exists())
                self.assertFalse((self.root / "home").exists())

    def test_no_cache_pulls_builder_without_mounting_offline_cache(self):
        result = self.launch("--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.root / "docker.json").read_text())
        self.assertIn("--pull=always", args)
        self.assertFalse(any("/airootfs/var/cache/omarchy" in arg for arg in args))


class Aarch64CustomizeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("boot/dtbs/qcom", "etc/mkinitcpio.d", "root", "tools", "usr/lib/modules/test"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / "boot/Image").write_bytes(b"kernel")
        (self.root / "etc/pacman.conf").write_text("[options]\nDisableSandbox\n")
        (self.root / "boot/dtbs/qcom/x1e78100-lenovo-thinkpad-t14s.dtb").write_bytes(b"base")
        (self.root / "root/t14-bluetooth.dtb").write_bytes(b"board")
        (self.root / "etc/mkinitcpio.d/linux-t2.preset").touch()
        script = (ROOT / "configs/aarch64/customize_airootfs.sh").read_text()
        # Redirect the production script's absolute live-root paths into a
        # disposable fixture. No chroot, root access or host /boot writes.
        for directory in ("boot", "etc", "root", "usr/lib/modules"):
            script = script.replace(f"/{directory}/", f"{self.root}/{directory}/")
        self.script = self.root / "customize.sh"
        self.script.write_text(script)
        self.env = dict(os.environ, PATH=f"{self.root}/tools:{os.environ['PATH']}",
                        TEST_ROOT=str(self.root), TEST_HOOKS="hooks/archiso\nhooks/archiso_loop_mnt")
        required = ["hooks/dragon_hp_thinkpad", "drivers/panel-edp.ko"]
        required += ["drivers/" + module + ".ko" for module in
                     ("nvme", "phy-qcom-qmp-pcie", "pwrseq-qcom-wcn", "pci-pwrctrl-pwrseq")]
        required += ["usr/lib/firmware/" + name for name in
                     ("qcom/gen70500_sqe.fw", "qcom/gen70500_gmu.bin", "qcom/x1e80100/gen70500_zap.mbn")]
        required += ["usr/lib/firmware/updates/qcom/x1e80100/" + board + "/" + name
                     for board in ("hp/elitebook-ultra-g1q", "LENOVO/21N1")
                     for name in ("qcadsp8380.mbn", "qccdsp8380.mbn", "cdsp_dtbs.elf")]
        self.env["TEST_HOOKS"] += "\n" + "\n".join(required)
        commands = {
            "tools/sha256sum": "cat >/dev/null",  # DT byte hashes are checked in real package preparation.
            "tools/modinfo": "echo module.ko",
            "tools/uname": "echo aarch64",
            "tools/stat": "echo 4",
            "tools/mkinitcpio": 'printf initrd > "$TEST_ROOT/boot/initramfs-linux-aarch64.img"',
            "tools/lsinitcpio": 'printf "%s\\n" "$TEST_HOOKS"',
            "root/live-uki.sh": 'touch "$TEST_ROOT/uki-built"',
        }
        for name, command in commands.items():
            executable = self.root / name
            executable.write_text(f"#!/bin/bash\n{command}\n")
            executable.chmod(0o755)

    def run_customize(self, target):
        (self.root / "root/omarchy_media_target").write_text(target + "\n")
        return subprocess.run(["bash", str(self.script)], env=self.env, capture_output=True, text=True)

    def test_snapdragon_builds_uki_after_live_initramfs_inspection(self):
        result = self.run_customize("aarch64/snapdragon")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "uki-built").exists())
        self.assertNotIn("DisableSandbox", (self.root / "etc/pacman.conf").read_text())
        self.assertEqual((self.root / "boot/dtbs/qcom/x1e78100-lenovo-thinkpad-t14s.dtb").read_bytes(), b"board")
        self.assertEqual((self.root / "boot/vmlinuz-linux-aarch64").read_bytes(), b"kernel")
        self.assertFalse((self.root / "etc/mkinitcpio.d/linux-t2.preset").exists())

    def test_missing_board_firmware_prevents_uki_build(self):
        self.env["TEST_HOOKS"] = self.env["TEST_HOOKS"].replace(
            "usr/lib/firmware/updates/qcom/x1e80100/LENOVO/21N1/cdsp_dtbs.elf", "")
        result = self.run_customize("aarch64/snapdragon")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing experimental firmware", result.stderr)
        self.assertFalse((self.root / "uki-built").exists())

    def test_generic_does_not_require_qualcomm_uki(self):
        (self.root / "root/live-uki.sh").unlink()
        result = self.run_customize("aarch64/generic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "uki-built").exists())

    def test_installed_root_initramfs_is_rejected_before_uki_build(self):
        self.env["TEST_HOOKS"] = "hooks/encrypt\nhooks/udev"
        result = self.run_customize("aarch64/snapdragon")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing archiso", result.stderr)
        self.assertFalse((self.root / "uki-built").exists())

    def test_failed_image_inspection_is_fatal(self):
        (self.root / "tools/lsinitcpio").write_text("#!/bin/bash\nexit 1\n")
        result = self.run_customize("aarch64/generic")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
