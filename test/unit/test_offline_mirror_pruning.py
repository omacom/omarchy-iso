#!/usr/bin/python

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRUNER = ROOT / "builder/prune-offline-mirror.sh"


class OfflineMirrorPruningTest(unittest.TestCase):
    def run_pruner(self, mirror: Path, required: list[str]):
        return subprocess.run(
            ["bash", str(PRUNER), str(mirror)],
            input="".join(f"{filename}\n" for filename in required),
            capture_output=True,
            text=True,
        )

    def add_file(self, mirror: Path, filename: str):
        (mirror / filename).write_bytes(b"package")

    def test_keeps_only_exactly_selected_package_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            mirror = Path(directory)
            keep = "keep-2.0-1-x86_64.pkg.tar.zst"
            other = "other-1.0-1-any.pkg.tar.zst"
            stale_version = "keep-1.0-1-x86_64.pkg.tar.zst"
            removed_package = "removed-1.0-1-x86_64.pkg.tar.zst"
            orphan_signature = "interrupted-1.0-1-x86_64.pkg.tar.zst.sig"

            for filename in (keep, other, stale_version, removed_package):
                self.add_file(mirror, filename)
            for filename in (keep, stale_version, removed_package):
                self.add_file(mirror, f"{filename}.sig")
            self.add_file(mirror, orphan_signature)
            self.add_file(mirror, "offline.db.tar.gz")

            result = self.run_pruner(mirror, [keep, other])

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                {path.name for path in mirror.iterdir()},
                {keep, f"{keep}.sig", other, "offline.db.tar.gz"},
            )
            self.assertIn(stale_version, result.stdout)
            self.assertIn(removed_package, result.stdout)

    def test_missing_selection_aborts_before_deleting_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            mirror = Path(directory)
            cached = "cached-1.0-1-x86_64.pkg.tar.zst"
            self.add_file(mirror, cached)

            result = self.run_pruner(
                mirror, ["missing-1.0-1-x86_64.pkg.tar.zst"]
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((mirror / cached).exists())
            self.assertIn("selected packages are missing", result.stderr)

    def test_empty_selection_aborts_before_deleting_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            mirror = Path(directory)
            cached = "cached-1.0-1-x86_64.pkg.tar.zst"
            self.add_file(mirror, cached)

            result = self.run_pruner(mirror, [])

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((mirror / cached).exists())
            self.assertIn("empty package selection", result.stderr)


if __name__ == "__main__":
    unittest.main()
