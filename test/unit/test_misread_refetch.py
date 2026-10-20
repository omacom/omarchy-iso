"""A package misread off the install medium is fetched again, not fatal."""
import ast
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
source = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py"
tree = ast.parse(source.read_text())
body = [
    node for node in tree.body
    if (isinstance(node, ast.FunctionDef) and node.name == "refetch_misread_packages")
    or (isinstance(node, ast.Assign) and node.targets[0].id == "MISREAD_RETRIES")
]

CORRUPT = (
    "Pacstrap failed: :: File /mnt/var/cache/pacman/pkg/libcmis-0.6.3-2-x86_64.pkg.tar.zst"
    " is corrupted (invalid or corrupted package (checksum))."
)


class RequirementError(Exception):
    pass


def load(outcomes):
    """Install the wrapper over a Pacman whose straps fail as listed."""
    calls = []

    class Pacman:
        def strap(self, packages):
            calls.append(packages)
            outcome = outcomes[len(calls) - 1]
            if outcome:
                raise RequirementError(outcome)

    exceptions = types.ModuleType("archinstall.lib.exceptions")
    exceptions.RequirementError = RequirementError
    pacman = types.ModuleType("archinstall.lib.pacman.pacman")
    pacman.Pacman = Pacman
    stubs = {"archinstall.lib.exceptions": exceptions, "archinstall.lib.pacman.pacman": pacman}

    namespace = {"info": lambda message: None}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(source), "exec"), namespace)
    with mock.patch.dict(sys.modules, stubs):
        namespace["refetch_misread_packages"]()
    return Pacman(), calls


class MisreadRefetchTest(unittest.TestCase):
    def test_corrupt_package_is_retried_until_it_installs(self):
        pacman, calls = load([CORRUPT, CORRUPT, None])
        pacman.strap(["libcmis"])
        self.assertEqual(len(calls), 3)

    def test_other_failures_are_not_retried(self):
        pacman, calls = load(["target not found: nope"])
        with self.assertRaises(RequirementError):
            pacman.strap(["nope"])
        self.assertEqual(len(calls), 1)

    def test_retries_are_bounded(self):
        pacman, calls = load([CORRUPT] * 10)
        with self.assertRaises(RequirementError):
            pacman.strap(["libcmis"])
        self.assertEqual(len(calls), 4)


if __name__ == "__main__":
    unittest.main()
