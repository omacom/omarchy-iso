#!/bin/bash
#
# Free-space installs are plan-only in the configurator: the configurator emits
# omarchy_install.free_space_plan into user_configuration.json without touching
# the disk, and the orchestrator verifies the install medium and validates the
# plan (prepare_install_target) before executing any partition/format/LUKS work
# (arch_install_system -> execute_free_space_plan). Assert both halves statically
# so a refactor can never re-introduce pre-gate disk writes.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"
phases_main="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py"
phases_impl="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py"
free_space="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/free_space.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Configurator free-space path is strictly plan-only (no disk execution).
non_comment=$(grep -vE '^[[:space:]]*#' "$configurator")
grep -qE '\bwrite_free_space_config\b' <<<"$non_comment" ||
  fail "configurator no longer emits free-space config via write_free_space_config"
grep -q '"free_space_plan"' "$configurator" ||
  fail "configurator no longer writes omarchy_install.free_space_plan"

for forbidden in 'run_partition_execute' 'create_partition' 'omarchy-luks-calibrate' \
  'cryptsetup ' 'mkfs\.btrfs' 'mkfs\.fat' 'wipefs ' 'parted --script'; do
  if grep -qE "$forbidden" <<<"$non_comment"; then
    fail "configurator still contains forbidden disk-execution command matching /$forbidden/"
  fi
done

# 2. Orchestrator verifies the install medium & plan before executing free-space partitioning.
[[ -f "$free_space" ]] || fail "missing orchestrator free-space executor: ${free_space#"$ROOT/"}"

python3 - "$phases_main" "$phases_impl" <<'EOF'
import ast
import sys
from pathlib import Path

phases_path, impl_path = Path(sys.argv[1]), Path(sys.argv[2])

phases_src = phases_path.read_text()
prep_idx = phases_src.find("prepare_install_target")
inst_idx = phases_src.find("arch_install_system")
if prep_idx < 0 or inst_idx < 0 or prep_idx >= inst_idx:
    sys.exit("FAIL: main.py must order prepare_install_target before arch_install_system")

tree = ast.parse(impl_path.read_text(), filename=str(impl_path))
funcs = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}

def calls_in(fn_name: str) -> set[str]:
    node = funcs.get(fn_name)
    if node is None:
        sys.exit(f"FAIL: {fn_name} not found in {impl_path}")
    names: set[str] = set()
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call):
            if isinstance(sub.func, ast.Name):
                names.add(sub.func.id)
            elif isinstance(sub.func, ast.Attribute):
                names.add(sub.func.attr)
    return names

prep_calls = calls_in("prepare_install_target")
inst_calls = calls_in("arch_install_system")

if "verify_install_medium" not in prep_calls:
    sys.exit("FAIL: prepare_install_target does not call verify_install_medium")
if "validate_free_space_plan" not in prep_calls:
    sys.exit("FAIL: prepare_install_target does not call validate_free_space_plan")
if "execute_free_space_plan" in prep_calls:
    sys.exit("FAIL: execute_free_space_plan must not run inside prepare_install_target")
if "execute_free_space_plan" not in inst_calls:
    sys.exit("FAIL: arch_install_system does not call execute_free_space_plan")
EOF

echo "ok: free-space configurator is plan-only and orchestrator gates verify/validate before execute"
