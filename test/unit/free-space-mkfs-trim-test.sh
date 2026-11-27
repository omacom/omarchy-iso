#!/bin/bash
#
# The free-space install creates a throwaway btrfs filesystem before the root
# image is written over it. mkfs.btrfs discards the whole partition first unless
# given -K, which through dm-crypt costs seconds on a 1 TB SSD. Assert the
# configurator no longer runs mkfs.btrfs and orchestrator/free_space.py passes -K.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"
free_space="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/free_space.py"

if grep -vE '^\s*#' "$configurator" | grep -qE '\bmkfs\.btrfs\b'; then
  echo "configurator must remain plan-only and not run mkfs.btrfs directly" >&2
  exit 1
fi

[[ -f "$free_space" ]] || { echo "missing ${free_space#"$ROOT/"}" >&2; exit 1; }

python3 - "$free_space" <<'EOF'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])
tree = ast.parse(path.read_text(), filename=str(path))
mkfs_lists = []
for node in ast.walk(tree):
    if isinstance(node, (ast.List, ast.Tuple)):
        elems = [
            e.value for e in node.elts
            if isinstance(e, ast.Constant) and isinstance(e.value, str)
        ]
        if elems and elems[0] == "mkfs.btrfs":
            mkfs_lists.append(elems)

if len(mkfs_lists) != 1:
    sys.exit(f"expected exactly one mkfs.btrfs command in {path}, found {len(mkfs_lists)}")
if "-K" not in mkfs_lists[0]:
    sys.exit(f"the free-space mkfs.btrfs runs without -K and TRIMs the whole partition: {mkfs_lists[0]}")
EOF

echo "ok: the free-space mkfs.btrfs in orchestrator/free_space.py skips whole-device TRIM"
