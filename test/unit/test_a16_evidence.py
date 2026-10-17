import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
from orchestrator.a16_evidence import stage_evidence


class EvidenceTest(unittest.TestCase):
    def fixture(self, root):
        target = root / "target"
        live = root / "live"
        for relative in (
            "usr/local/bin/omarchy-a16-evidence",
            "usr/share/omarchy-iso/omarchy-a16-first-boot-evidence",
            "usr/share/omarchy-iso/omarchy-a16-evidence.service",
            "usr/share/omarchy-iso/build-info",
        ):
            path = live / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        kernel = target / "usr/lib/modules/7.2.10-3-omarchy/vmlinuz"
        for path in (
            kernel,
            target / "boot/dtbs/linux-omarchy/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb",
            target / "boot/EFI/Linux/omarchy_linux-omarchy.efi",
            target / "boot/limine.conf",
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"artifact bytes")
        (kernel.parent / "pkgbase").write_text("linux-omarchy\n")
        return target, live, kernel

    def test_hashes_permissions_service_and_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            target, live, kernel = self.fixture(Path(tmp))
            for _ in range(2):
                stage_evidence(target, target / "boot", live)
            state = target / "var/lib/omarchy/a16-evidence"
            receipt = state / "install-receipt.json"
            data = json.loads(receipt.read_text())
            self.assertEqual(data["sha256"][str(kernel.relative_to(target))], hashlib.sha256(kernel.read_bytes()).hexdigest())
            self.assertEqual(len(data["sha256"]), 5)
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertTrue((target / "etc/systemd/system/multi-user.target.wants/omarchy-a16-evidence.service").resolve().is_file())
            self.assertEqual((target / "usr/local/bin/omarchy-a16-evidence").stat().st_mode & 0o777, 0o755)

    def test_missing_or_empty_artifact_cannot_be_recorded_as_success(self):
        for empty in (False, True):
            with self.subTest(empty=empty), tempfile.TemporaryDirectory() as tmp:
                target, live, kernel = self.fixture(Path(tmp))
                if empty:
                    kernel.write_bytes(b"")
                else:
                    kernel.unlink()
                with self.assertRaises(RuntimeError):
                    stage_evidence(target, target / "boot", live)
                self.assertFalse((target / "var/lib/omarchy/a16-evidence/install-receipt.json").exists())

    def test_shared_kernel_is_recorded_without_a_version_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            target, live, old = self.fixture(Path(tmp))
            new = target / "usr/lib/modules/7.2.11-2-omarchy"
            old.parent.rename(new)
            (new / "pkgbase").write_text("linux-omarchy\n")
            stage_evidence(target, target / "boot", live, kernel="linux-omarchy")
            receipt = json.loads((target / "var/lib/omarchy/a16-evidence/install-receipt.json").read_text())
            self.assertEqual(receipt["kernel_package"], "linux-omarchy")
            self.assertIn(str((new / "vmlinuz").relative_to(target)), receipt["sha256"])


if __name__ == "__main__":
    unittest.main()
