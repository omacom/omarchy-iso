"""Unit tests for the live system's initramfs hook, Try layer build, dedup, and ISO gates."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "configs/airootfs/etc/initcpio/hooks/omarchy_try"
TRY_LAYER = ROOT / "builder/build-try-layer.sh"
BUILD_ISO = ROOT / "builder/build-iso.sh"
DEDUP = ROOT / "builder/dedup-airootfs.sh"
SHIM = ROOT / "builder/mksquashfs-shim/mksquashfs"


class OmarchyTryHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.log = self.dir / "calls.log"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "LOG": str(self.log),
        }

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def run_hook_fn(self, script):
        return subprocess.run(
            ["sh", "-c", f'. "{HOOK}"\n{script}'],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def test_boot_failed_quits_plymouth_before_shell(self):
        self.stub("plymouth", 'echo "plymouth $*" >>"$LOG"; exit 0')
        self.stub("reboot", 'echo "reboot $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn(
            'err() { echo "err $*" >>"$LOG"; }\n'
            'launch_interactive_shell() { echo "shell" >>"$LOG"; }\n'
            'boot_failed "boom"'
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "plymouth --ping",
                "plymouth --wait quit",
                "err Omarchy: boom. Nothing has been installed; the machine restarts when you leave this shell.",
                "shell",
                "reboot -f",
            ],
        )

    def test_boot_failed_skips_plymouth_quit_when_not_running(self):
        self.stub("plymouth", 'echo "plymouth $*" >>"$LOG"; [ "$1" = "--ping" ] && exit 1; exit 0')
        self.stub("reboot", 'echo "reboot $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn(
            'err() { echo "err $*" >>"$LOG"; }\n'
            'launch_interactive_shell() { echo "shell" >>"$LOG"; }\n'
            'boot_failed "boom"'
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertNotIn("plymouth --wait quit", calls)
        self.assertIn("shell", calls)

    def test_mount_image_falls_back_when_threads_multi_refused(self):
        self.stub("mkdir", 'echo "mkdir $*" >>"$LOG"; exit 0')
        self.stub(
            "mount",
            'echo "mount $*" >>"$LOG"\n'
            'case "$*" in *threads=multi*) exit 32 ;; esac\n'
            'exit 0',
        )
        self.stub("losetup", 'echo "losetup $*" >>"$LOG"; echo /dev/loop9')
        res = self.run_hook_fn('mount_image /medium/omarchy-root.sfs')
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "mkdir -p /run/omarchy-root/sfs /run/omarchy-root/image",
                "mount -t squashfs -o ro,loop,threads=multi /medium/omarchy-root.sfs /run/omarchy-root/sfs",
                "mount -t squashfs -o ro,loop /medium/omarchy-root.sfs /run/omarchy-root/sfs",
                "losetup --find --show --read-only -- /run/omarchy-root/sfs/omarchy-root.img",
                "mount -t btrfs -o ro,subvol=omarchy-root /dev/loop9 /run/omarchy-root/image",
            ],
        )

    def test_mount_image_cleans_up_on_btrfs_failure(self):
        self.stub("mkdir", 'exit 0')
        self.stub(
            "mount",
            'echo "mount $*" >>"$LOG"\n'
            'case "$*" in *-t\\ btrfs*) exit 32 ;; esac\n'
            'exit 0',
        )
        self.stub(
            "losetup",
            'echo "losetup $*" >>"$LOG"\n'
            'case "$1" in -d) exit 0 ;; esac\n'
            'echo /dev/loop9',
        )
        self.stub("umount", 'echo "umount $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn('mount_image /medium/omarchy-root.sfs')
        self.assertNotEqual(res.returncode, 0)
        calls = self.log.read_text().splitlines()
        self.assertIn("losetup -d /dev/loop9", calls)
        self.assertIn("umount /run/omarchy-root/sfs", calls)

    def test_live_overlay_sets_index_off(self):
        self.assertIn("workdir=/run/archiso/cowspace/${cow_directory}/workdir,index=off", HOOK.read_text())


class BuildTryLayerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = TRY_LAYER.read_text()

    def test_enables_bluetooth_and_retires_networkd(self):
        self.assertRegex(self.text, r"sddm\.service\s+systemd-oomd\.service\s+bluetooth\.service")
        self.assertIn("systemd-networkd.service", self.text)
        self.assertIn("systemd-networkd-wait-online.service", self.text)

    def test_masks_disk_and_hibernate_units(self):
        for unit in (
            "systemd-hibernate-clear.service",
            "lvm2-monitor.service",
            "lvm2-lvmpolld.socket",
            "systemd-boot-random-seed.service",
            "snapper-timeline.timer",
            "limine-snapper-sync.service",
        ):
            self.assertIn(unit, self.text, f"{unit} should be masked in Try")

    def test_keyring_service_does_not_run_pacman_sy(self):
        m = re.search(
            r"omarchy-try-keyring\.service\" <<'EOF'\n(.*?)\nEOF",
            self.text,
            re.S,
        )
        self.assertIsNotNone(m)
        unit = m.group(1)
        self.assertIn("pacman-key --init && pacman-key --populate", unit)
        self.assertNotIn("pacman -Sy", unit)

    def test_isolates_build_host_hardware_during_user_provisioning(self):
        for stub in ("omarchy-hw-vm", "omarchy-hw-asus-rog", "omarchy-hw-match", "omarchy-hw-pci"):
            self.assertIn(stub, self.text)
        self.assertIn('for target in "$merged/usr/bin/$cmd" "$merged/usr/share/omarchy/bin/$cmd"; do', self.text)
        self.assertIn('[[ -f $target && ! -L $target ]]', self.text)
        self.assertIn("OMARCHY_PCI_DEVICES_PATH=/dev/null", self.text)
        self.assertIn("OMARCHY_NOUVEAU_DRIVER_PATH=/dev/null", self.text)

    def test_guards_nvidia_lua_when_proprietary_driver_absent(self):
        # The running driver, not a layer's config: a card nouveau kept after a
        # failed handover from the installer must not get NVIDIA's variables.
        self.assertIn('io.open("/sys/module/nvidia_drm/initstate", "r")', self.text)
        self.assertIn("no_hardware_cursors = true", self.text)

    def test_driver_layer_stubs_systemctl_on_pass_one_only(self):
        self.assertIn('printf \'#!/bin/sh\\nexit 0\\n\' >"$stubs/systemctl"', self.text)
        self.assertIn('rm -f "$stubs/systemctl"', self.text)

    def test_the_bar_does_not_read_trys_sudo_as_a_warning(self):
        # omarchy-sudo-passwordless --active asks sudo for its own __status;
        # the last matching rule needs a password, every other command none.
        self.assertIn(
            "printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\\n%s ALL=(ALL:ALL) PASSWD: /usr/bin/omarchy-sudo-passwordless\\n'",
            self.text,
        )

    def test_idles_as_an_install_does(self):
        # Stay awake was on in every Try session; Omarchy's idle lock turns
        # itself down without the lock screen's PAM file, which Try lacks.
        self.assertNotIn("indicators/stay-awake", self.text)
        self.assertNotRegex(self.text, r"pam\.d/omarchy-lock-password[^\n]*<<")

    def test_arms_no_watchdog_for_a_reboot_from_try(self):
        # Closing it printed "watchdog did not stop!" over the screen.
        m = re.search(r"/etc/systemd/system.conf.d/90-omarchy-try.conf\" <<'EOF'\n(.*?)\nEOF", self.text, re.S)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1).split(), ["[Manager]", "RebootWatchdogSec=0"])

    def test_runs_the_installs_hardware_setup_from_the_offline_repository(self):
        m = re.search(r"omarchy-try-hardware\.service\" <<'EOF'\n(.*?)\nEOF", self.text, re.S)
        self.assertIsNotNone(m)
        unit = m.group(1).splitlines()
        self.assertIn("BindReadOnlyPaths=/run/omarchy-try/pacman-offline.conf:/etc/pacman.conf", unit)
        # Detection and pacman's ldconfig take seconds: not before the desktop,
        # and not holding multi-user.target up either.
        self.assertNotIn("Before=display-manager.service", unit)
        self.assertIn("Type=exec", unit)
        m = re.search(r"omarchy-try-hardware-user\.service\" <<'EOF'\n(.*?)\nEOF", self.text, re.S)
        self.assertIsNotNone(m)
        self.assertIn("Before=display-manager.service", m.group(1).splitlines())
        self.assertIn("in_try systemctl enable omarchy-try-hardware.service omarchy-try-hardware-user.service", self.text)
        script = (ROOT / "builder/try-layer/omarchy-try-hardware").read_text()
        self.assertIn('omarchy-apply-hardware --install-user "$user"', script)
        for name in ("mkinitcpio", "dkms", "limine-entry-tool", "limine-update", "ukify"):
            self.assertIn(name, self.text.split("for tool in ", 1)[1].split(";", 1)[0])
        # The user manager's reload hook re-executed it under a starting session.
        for hook in ("60-mkinitcpio-remove.hook", "60-limine-mkinitcpio-remove-pre.hook", "80-limine-efi-deploy.hook",
                     "90-limine-mkinitcpio-remove-post.hook", "90-mkinitcpio-install.hook",
                     "30-systemd-daemon-reload-user.hook"):
            self.assertIn(hook, self.text)

    def test_says_once_what_the_session_is(self):
        welcome = (ROOT / "builder/try-layer/omarchy-try-welcome").read_text()
        # The glyph is its own argument; without one, -g takes the title.
        self.assertRegex(welcome, r"omarchy-notification-send -u critical -g \$'\\u[0-9a-f]{4}' \"Try Omarchy!\"")
        self.assertIn('"Install apps, change themes, anything. When you\'re sold, reboot and pick install instead."', welcome)
        self.assertIn("in_try systemctl --global enable omarchy-try-welcome.service", self.text)

    def test_sets_utf8_locale_and_browser_policies(self):
        self.assertIn("LANG=en_US.UTF-8", self.text)
        self.assertIn("browser-policy.sh", self.text)
        self.assertIn("theme-system.sh", self.text)

    def test_hardens_sddm_autologin_state_greeter_and_session_wrapper(self):
        self.assertIn("sddm.service.d/10-omarchy-try-udev.conf", self.text)
        self.assertIn("udevadm settle --timeout=10", self.text)
        self.assertIn("Current=omarchy-try", self.text)
        self.assertIn("Relogin=true", self.text)
        self.assertIn("/var/lib/sddm/state.conf", self.text)
        self.assertIn("chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf", self.text)
        self.assertIn("omarchy-try-session", self.text)
        self.assertIn('sddm.login("$TRY_USER", "", root.sessionIndex)', self.text)


class LiveSystemLeavesTheMachineTest(unittest.TestCase):
    # Every boot runs the live installer first, Just try included.
    def test_the_live_rtc_is_local_and_hibernate_state_is_kept(self):
        text = (ROOT / "configs/airootfs/root/customize_airootfs.sh").read_text()
        self.assertIn("printf '0.0 0 0\\n0\\nLOCAL\\n' >/etc/adjtime", text)
        self.assertIn("systemctl mask systemd-hibernate-clear.service", text)
        self.assertIn("ln -sf /dev/null /etc/udev/rules.d/64-md-raid-assembly.rules", text)
        # Before anything that can end the script early.
        self.assertLess(text.index("LOCAL"), text.index("fw=/usr/lib/firmware"))


class DedupAndBuildIsoTest(unittest.TestCase):
    def test_dedup_keeps_firmware_dbus_polkit_and_creates_missing_keep_dirs(self):
        text = DEDUP.read_text()
        for rel in ("usr/lib/firmware", "usr/share/dbus-1", "usr/share/polkit-1"):
            self.assertIn(f'"{rel}"', text)
        # Extract and run the embedded Python dedup logic on synthetic trees.
        py_src = re.search(r"python3 - .*?<<'PY'\n(.*?)\nPY", text, re.S).group(1)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            live = tmp / "live"
            image = tmp / "image"
            pseudo = tmp / "pseudo"
            # Directory present in image and in KEEP, absent from live -> must become opaque!
            (image / "usr/lib/firmware/iwlwifi").mkdir(parents=True)
            (image / "usr/lib/firmware/iwlwifi/test.ucode").write_bytes(b"fw")
            (live / "etc").mkdir(parents=True)
            # Identical file outside KEEP -> must be deduplicated!
            (live / "usr/bin").mkdir(parents=True)
            (image / "usr/bin").mkdir(parents=True)
            (live / "usr/bin/same").write_bytes(b"hello")
            (image / "usr/bin/same").write_bytes(b"hello")
            (live / "usr/bin/diff").write_bytes(b"live-version")
            (image / "usr/bin/diff").write_bytes(b"image-version")

            res = subprocess.run(
                ["python3", "-c", py_src, str(live), str(image), str(pseudo)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertFalse((live / "usr/bin/same").exists())
            self.assertTrue((live / "usr/bin/diff").exists())
            self.assertTrue((live / "usr/lib/firmware").is_dir())
            pseudo_lines = pseudo.read_text().splitlines()
            self.assertIn("/usr/lib/firmware x trusted.overlay.opaque=y", pseudo_lines)
            self.assertIn("/etc x trusted.overlay.opaque=y", pseudo_lines)
            self.assertTrue((live / "etc/omarchy-iso-live-over-image").is_file())

    def test_dedup_creates_missing_loop_node_before_attaching(self):
        text = DEDUP.read_text()
        self.assertNotIn("-o ro,loop", text)
        self.assertNotIn("losetup --find --show", text)
        fn = re.search(r"attach_ro_loop\(\) \{.*?\n\}", text, re.S).group(0)
        minor = next(n for n in range(99, 10000) if not Path(f"/dev/loop{n}").exists())
        dev = f"/dev/loop{minor}"
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            stub_bin = tmp / "bin"
            stub_bin.mkdir()
            log = tmp / "calls.log"
            (stub_bin / "losetup").write_text(
                '#!/bin/sh\n'
                'echo "losetup $*" >>"$LOG"\n'
                f'if [ "$1" = "--find" ]; then echo "{dev} (lost)"; exit 0; fi\n'
                'exit "${LOSETUP_ATTACH_RC:-0}"\n'
            )
            (stub_bin / "mknod").write_text('#!/bin/sh\necho "mknod $*" >>"$LOG"\n')
            for name in ("losetup", "mknod"):
                (stub_bin / name).chmod(0o755)
            env = {"PATH": f"{stub_bin}:/usr/bin:/bin", "LOG": str(log)}
            res = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", f'{fn}\ndev=$(attach_ro_loop /tmp/backing.img)\nprintf "%s\\n" "$dev"'],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(res.stdout.strip(), dev)
            calls = log.read_text().splitlines()
            self.assertIn(f"mknod {dev} b 7 {minor}", calls)
            self.assertIn(f"losetup --read-only {dev} /tmp/backing.img", calls)

            # Command substitution drops errexit in Bash: a failed attach must
            # still fail attach_ro_loop without printing a device path.
            fail_res = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", f'{fn}\ndev=$(attach_ro_loop /tmp/backing.img)\nprintf "%s\\n" "$dev"'],
                env={**env, "LOSETUP_ATTACH_RC": "1"},
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(fail_res.returncode, 0)
            self.assertEqual(fail_res.stdout.strip(), "")

    def test_mksquashfs_shim_cleans_up_pseudo_file(self):
        shim_text = SHIM.read_text()
        self.assertIn('trap \'rm -f "$pseudo"\' EXIT', shim_text)
        self.assertNotIn('exec /usr/bin/mksquashfs "$@" -pf "$pseudo"', shim_text)

    def test_oem_iso_skips_try_layer(self):
        # Without the layer the installer never asks Install or Try.
        text = BUILD_ISO.read_text()
        self.assertIn('[[ $OMARCHY_ARCH == x86_64 && ${OMARCHY_OEM_INSTALL:-} != "1" ]]', text)

    def test_iso_size_gate_checks_only_newly_built_isos_after_chown(self):
        text = BUILD_ISO.read_text()
        self.assertIn('iso_staging=$(mktemp -d /out/.omarchy-iso-out.XXXXXX)', text)
        self.assertIn('for iso in "${built_isos[@]}"; do', text)
        self.assertNotIn("for iso in /out/*.iso; do", text)
        self.assertLess(text.index('chown -R "$HOST_UID:$HOST_GID" /out/'), text.index("iso_fail_bytes="))


if __name__ == "__main__":
    unittest.main()
