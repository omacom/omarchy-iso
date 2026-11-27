#!/bin/bash
#
# Both the Windows ESP probe (configurator) and the new free-space ESP mount
# (orchestrator/free_space.py) must name -t vfat explicitly. Untyped, mount
# takes the type from udev's database, which records a new filesystem a few
# milliseconds after mkfs.fat closes the device; until then mount walks
# /proc/filesystems, and on a fresh live boot (no vfat module loaded yet) that
# ends at squashfs: "Can't find a SQUASHFS superblock".

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"
free_space="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/free_space.py"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'mount -t vfat -o ro "$p"' "$configurator" || fail "the Windows ESP probe mounts without its type"
if grep -nE '(^|[^-])mount (-o [^ ]+ )?"\$(efi_dev|p)"' "$configurator"; then
  fail "an ESP is mounted without its type in configurator"
fi

[[ -f "$free_space" ]] || fail "missing ${free_space#"$ROOT/"}"

python3 - "$free_space" <<'EOF'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])
tree = ast.parse(path.read_text(), filename=str(path))
vfat_mounts = 0
for node in ast.walk(tree):
    if isinstance(node, (ast.List, ast.Tuple)):
        elems = [
            e.value for e in node.elts
            if isinstance(e, ast.Constant) and isinstance(e.value, str)
        ]
        if elems and elems[0] == "mount":
            for i in range(len(elems) - 1):
                if elems[i] == "-t" and elems[i + 1] == "vfat":
                    vfat_mounts += 1
if vfat_mounts < 1:
    sys.exit(f"FAIL: no typed mount -t vfat call found in {path}")
EOF

echo "ok - every ESP mount names vfat"
