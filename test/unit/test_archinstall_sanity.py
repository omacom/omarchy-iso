"""Exercise the compatibility boundary without importing host archinstall."""
import ast
from pathlib import Path
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]
source = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py"
tree = ast.parse(source.read_text())
namespace = {}
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in {"_method_accepts", "sanity_check"}]
exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), "exec"), namespace)


class SanityCheckTest(unittest.TestCase):
    def test_legacy_archinstall_stays_offline(self):
        calls = []
        def check(offline=False, skip_ntp=False, skip_wkd=False):
            calls.append((offline, skip_ntp, skip_wkd))
        namespace["sanity_check"](types.SimpleNamespace(sanity_check=check))
        self.assertEqual(calls, [(True, True, True)])

    def test_archinstall_45_does_not_receive_removed_argument(self):
        calls = []
        class Installer:
            def sanity_check(self, skip_ntp=False, skip_wkd=False):
                calls.append((skip_ntp, skip_wkd))
        namespace["sanity_check"](Installer())
        self.assertEqual(calls, [(True, True)])
