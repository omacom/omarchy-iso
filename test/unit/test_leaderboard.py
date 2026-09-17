"""Unit tests for the sealed install timing artifact (orchestrator/leaderboard.py).

Runs the real phase loop over fake phases against a temp target, with the
live-environment probes pointed at a fixture tree and the block-device and
virtualisation commands mocked. The seal is checked with nothing but openssl,
the same way the installed system will check it.
"""

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import leaderboard, phases  # noqa: E402


LSBLK_NVME = json.dumps({
    "blockdevices": [{
        "name": "root", "type": "crypt", "model": None, "tran": None, "rota": False, "size": "952G",
        "children": [{
            "name": "nvme0n1p2", "type": "part", "model": None, "tran": None, "rota": False, "size": "952G",
            "children": [{
                "name": "nvme0n1", "type": "disk", "model": "SAMSUNG MZAL81T0HFLB-00BL2",
                "tran": "nvme", "rota": False, "size": "953.9G",
            }],
        }],
    }],
})

LSBLK_USB = json.dumps({
    "blockdevices": [{
        "name": "sdb1", "type": "part", "model": None, "tran": None, "rota": True, "size": "57.3G",
        "children": [{
            "name": "sdb", "type": "disk", "model": "SanDisk Ultra", "tran": "usb", "rota": True, "size": "57.3G",
        }],
    }],
})


def slow_phase(ctx):
    pass


def quick_phase(ctx):
    pass


def failing_phase(ctx):
    raise RuntimeError("boom")


class LeaderboardFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.target = root / "target"
        self.state_dir = root / "state"
        self.live = root / "live"
        self.target.mkdir()
        self.live.mkdir()

        # The live medium as build-iso.sh leaves it.
        self.write_live("root/omarchy_iso_ref", "quattro\n")
        self.write_live("root/omarchy_mirror", "stable\n")
        self.write_live("usr/share/omarchy-iso/build-info", "iso_ref=quattro\nmirror=stable\n")
        self.write_live("var/cache/omarchy/mirror/offline/offline.db.tar.gz", "not really a db")
        self.write_live("sys/class/dmi/id/sys_vendor", "LENOVO\n")
        self.write_live("sys/class/dmi/id/product_name", "83QK\n")
        self.write_live("sys/class/dmi/id/product_version", "Yoga Slim 7 Ultra 14IPH11\n")
        self.write_live("sys/class/dmi/id/board_name", "LNVNB161216\n")
        self.write_live("proc/cpuinfo", "processor\t: 0\nmodel name\t: Intel(R) Core(TM) Ultra 7 258V\n")
        self.write_live("proc/meminfo", "MemTotal:       31752064 kB\nMemFree:  1 kB\n")
        self.write_live("proc/uptime", "184.52 1200.00\n")

        # The target's pacman database, as far as the release lookup reads it.
        desc = self.target / "var/lib/pacman/local/omarchy-4.0.2-1/desc"
        desc.parent.mkdir(parents=True)
        desc.write_text("%NAME%\nomarchy\n\n%VERSION%\n4.0.2-1\n\n")
        (self.target / "var/lib/pacman/local/omarchy-settings-4.0.2-1").mkdir()

        patcher = mock.patch.object(leaderboard, "LIVE_ROOT", self.live)
        patcher.start()
        self.addCleanup(patcher.stop)

        self.commands = {
            ("systemd-detect-virt",): (1, "none\n"),
            ("findmnt", "-no", "SOURCE", str(self.target)): (0, "/dev/mapper/root[/@]\n"),
            ("findmnt", "-no", "SOURCE", str(self.live / "run/archiso/bootmnt")): (0, "/dev/sdb1\n"),
            ("lsblk", "-sJ", "-o", "NAME,TYPE,MODEL,TRAN,ROTA,SIZE", "/dev/mapper/root"): (0, LSBLK_NVME),
            ("lsblk", "-sJ", "-o", "NAME,TYPE,MODEL,TRAN,ROTA,SIZE", "/dev/sdb1"): (0, LSBLK_USB),
        }
        real_run = leaderboard.subprocess.run

        def fake_run(cmd, *args, **kwargs):
            key = tuple(cmd)
            if key in self.commands:
                code, out = self.commands[key]
                return types.SimpleNamespace(returncode=code, stdout=out, stderr="")
            if cmd[0] == "openssl":
                return real_run(cmd, *args, **kwargs)
            raise AssertionError(f"unexpected command {cmd}")

        patcher = mock.patch.object(leaderboard.subprocess, "run", side_effect=fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

        # Not btrfs in the fixture: the factory copy is a no-op here.
        patcher = mock.patch("orchestrator.phases_impl._findmnt_value", return_value="ext4")
        patcher.start()
        self.addCleanup(patcher.stop)

        patcher = mock.patch("orchestrator.phases_impl._provision_install_encrypted", return_value=True)
        self.encrypted = patcher.start()
        self.addCleanup(patcher.stop)

        env = mock.patch.dict(os.environ, {}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("OMARCHY_NO_PREFETCH", None)

    def write_live(self, relative, text):
        path = self.live / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def ctx(self, mode="full_disk"):
        return types.SimpleNamespace(
            target=self.target,
            state_dir=self.state_dir,
            mode=mode,
            user_configuration={},
            omarchy_install={},
            encrypt=False,
            state={},
        )

    def run_phases(self, phase_list=None):
        phase_list = phase_list or [
            ("Installing Arch + Omarchy", slow_phase),
            ("Configuring DNS resolver", quick_phase),
        ]
        with mock.patch("orchestrator.phases.info"), mock.patch("orchestrator.leaderboard.info"):
            phases.run(self.ctx(), phase_list)

    def document(self):
        return json.loads((self.target / "var/log/omarchy-install-timing.json").read_text())

    def artifact(self, name):
        return self.target / "var/lib/omarchy/leaderboard" / name


class ClassAndIdentityTest(LeaderboardFixture):
    def test_class_is_what_the_installer_observed(self):
        self.commands[("systemd-detect-virt",)] = (0, "kvm\n")
        self.run_phases()
        self.assertEqual(self.document()["class"], {
            "mode": "full_disk", "encrypted": True, "virt": "kvm", "warm": True,
        })

    def test_prefetch_off_is_a_cold_class(self):
        os.environ["OMARCHY_NO_PREFETCH"] = "1"
        self.encrypted.return_value = False
        self.run_phases()
        self.assertEqual(self.document()["class"], {
            "mode": "full_disk", "encrypted": False, "virt": "none", "warm": False,
        })

    def test_iso_release_and_hardware(self):
        self.run_phases()
        doc = self.document()

        self.assertEqual(doc["iso"]["ref"], "quattro")
        self.assertEqual(doc["iso"]["mirror"], "stable")
        self.assertEqual(doc["iso"]["build"], {"iso_ref": "quattro", "mirror": "stable"})
        self.assertEqual(len(doc["iso"]["offline_db_sha256"]), 64)
        self.assertEqual(doc["release"], {"package": "omarchy", "version": "4.0.2-1"})

        hw = doc["hardware"]
        self.assertEqual(hw["vendor"], "LENOVO")
        self.assertEqual(hw["product"], "83QK")
        self.assertEqual(hw["product_version"], "Yoga Slim 7 Ultra 14IPH11")
        self.assertEqual(hw["cpu"], "Intel(R) Core(TM) Ultra 7 258V")
        self.assertEqual(hw["memory_kb"], 31752064)
        self.assertEqual(hw["target_disk"], {
            "type": "disk", "model": "SAMSUNG MZAL81T0HFLB-00BL2", "transport": "nvme",
            "rotational": False, "size": "953.9G",
        })
        self.assertEqual(hw["install_medium"]["model"], "SanDisk Ultra")
        self.assertEqual(hw["install_medium"]["transport"], "usb")
        self.assertAlmostEqual(doc["live"]["uptime_s"], 184.52)
        self.assertIsNone(doc["attestation"])

    def test_nothing_identifying_is_recorded(self):
        self.write_live("etc/hostname", "pauls-laptop\n")
        self.write_live("sys/class/dmi/id/product_serial", "PF4ABCDE\n")
        self.run_phases()
        text = (self.target / "var/log/omarchy-install-timing.json").read_text()
        self.assertNotIn("pauls-laptop", text)
        self.assertNotIn("PF4ABCDE", text)
        self.assertNotIn("serial", text)

    def test_a_failed_probe_still_writes_and_seals_the_document(self):
        with mock.patch.object(leaderboard, "describe_hardware", side_effect=OSError("no sysfs")), \
                mock.patch("orchestrator.leaderboard.info"):
            self.run_phases()
        doc = self.document()
        self.assertIsNone(doc["hardware"])
        self.assertEqual(doc["class"]["mode"], "full_disk")
        self.assertIsNotNone(doc["seal"])
        self.assertTrue(self.artifact("timing.sig").exists())


class SealTest(LeaderboardFixture):
    def test_signature_verifies_and_tampering_breaks_it(self):
        self.run_phases()
        document = self.artifact("timing.json")
        signature = self.artifact("timing.sig")
        public_key = self.artifact("install.pub")

        self.assertEqual(document.read_bytes(), (self.target / "var/log/omarchy-install-timing.json").read_bytes())
        self.assertEqual(len(signature.read_bytes()), 64)
        self.assertTrue(leaderboard.verify(public_key, document, signature))

        doc = json.loads(document.read_text())
        self.assertEqual(doc["seal"]["algorithm"], "ed25519")
        pem_body = "".join(
            line for line in public_key.read_text().splitlines() if not line.startswith("-----")
        )
        self.assertEqual(doc["seal"]["public_key"], pem_body)

        # One phase, one nanosecond faster.
        doc["phases"][0]["elapsed_ns"] -= 1
        edited = self.target / "edited.json"
        edited.write_text(json.dumps(doc, indent=2) + "\n")
        self.assertFalse(leaderboard.verify(public_key, edited, signature))

        # Even a byte that changes no value.
        edited.write_bytes(document.read_bytes() + b"\n")
        self.assertFalse(leaderboard.verify(public_key, edited, signature))

    def test_private_key_is_nowhere_on_the_target_or_in_state(self):
        self.run_phases()
        for root in (self.target, self.state_dir):
            for path in root.rglob("*"):
                if path.is_file():
                    self.assertNotIn(b"PRIVATE KEY", path.read_bytes(), path)

    def test_seal_is_omitted_when_openssl_is_missing(self):
        with mock.patch.object(leaderboard, "generate_keypair", side_effect=FileNotFoundError("openssl")), \
                mock.patch("orchestrator.leaderboard.info"):
            self.run_phases()
        doc = self.document()
        self.assertIsNone(doc["seal"])
        self.assertEqual(doc["schema"], 1)
        self.assertFalse(self.artifact("timing.sig").exists())
        self.assertFalse(self.artifact("install.pub").exists())
        self.assertTrue(self.artifact("timing.json").exists())

    def test_sign_rejects_a_bad_key(self):
        document = self.target / "doc.json"
        document.write_text("{}\n")
        with self.assertRaises(RuntimeError):
            leaderboard.sign(b"-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----\n", document)


class FactoryCopyTest(LeaderboardFixture):
    def test_copies_into_a_reopened_factory_snapshot(self):
        top = self.state_dir / "factory-top"
        factory = top / "@factory"
        factory.mkdir(parents=True)
        calls = []

        def fake_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        def findmnt(path, column):
            return {"FSTYPE": "btrfs", "SOURCE": "/dev/mapper/root[/@]"}[column]

        with mock.patch("orchestrator.phases_impl._findmnt_value", side_effect=findmnt), \
                mock.patch.object(leaderboard.subprocess, "run", side_effect=fake_run):
            self.artifact("timing.json").parent.mkdir(parents=True)
            self.artifact("timing.json").write_text("{}\n")
            self.artifact("timing.sig").write_bytes(b"s" * 64)
            leaderboard.copy_into_factory(self.ctx())

        self.assertEqual(calls[0], ["mount", "-o", "subvolid=5", "/dev/mapper/root", str(top)])
        self.assertIn(["btrfs", "property", "set", "-ts", str(factory), "ro", "false"], calls)
        self.assertIn(["btrfs", "property", "set", "-ts", str(factory), "ro", "true"], calls)
        self.assertEqual(calls[-1], ["umount", str(top)])
        self.assertEqual((factory / "var/lib/omarchy/leaderboard/timing.json").read_text(), "{}\n")
        self.assertEqual((factory / "var/lib/omarchy/leaderboard/timing.sig").read_bytes(), b"s" * 64)

    def test_no_op_without_btrfs(self):
        with mock.patch.object(leaderboard.subprocess, "run") as run:
            leaderboard.copy_into_factory(self.ctx())
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
