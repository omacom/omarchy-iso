import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = ROOT / "builder/local-repo-config.sh"


class LocalRepoConfigTest(unittest.TestCase):
    def test_local_repository_precedes_distribution_repositories(self):
        for mirror in ("stable", "edge", "rc"):
            with self.subTest(mirror=mirror):
                config = ROOT / f"configs/pacman-online-{mirror}.conf"
                original = config.read_text()
                result = subprocess.check_output(
                    ["bash", str(CONFIGURATOR), str(config)], text=True
                )
                sections = re.findall(r"^\[([^]]+)\]$", result, re.MULTILINE)
                original_sections = re.findall(
                    r"^\[([^]]+)\]$", original, re.MULTILINE
                )
                self.assertEqual(sections[:2], ["options", "omarchy"])
                self.assertEqual(sections.count("omarchy"), 1)
                self.assertEqual(
                    sections[2:],
                    [name for name in original_sections if name not in ("options", "omarchy")],
                )
                self.assertIn("Server = file:///omarchy-repo", result)
                self.assertNotIn("https://pkgs.omarchy.org/", result)
                self.assertEqual(result.split("[omarchy]")[0], original.split("[omarchy]")[0])
                self.assertIn("SigLevel    = Required DatabaseOptional", result)
                with tempfile.TemporaryDirectory() as directory:
                    configured = Path(directory) / "pacman.conf"
                    configured.write_text(result)
                    repeated = subprocess.check_output(
                        ["bash", str(CONFIGURATOR), str(configured)], text=True
                    )
                self.assertEqual(result, repeated)
