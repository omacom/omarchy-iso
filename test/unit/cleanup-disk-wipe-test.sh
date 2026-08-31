#!/bin/bash
#
# clear_signatures() — the whole-disk/partition signature scrub the full-disk
# cleanup now performs — must wipe a stale signature the way a reinstall over a
# previous install leaves behind (issue #137: a stale LUKS/btrfs header survives
# holder-release and aborts archinstall's per-partition wipe mid-install).
#
# wipefs operates on image files, so this needs no root, no loop devices, and no
# real disk. We source the helper out of the installed cleanup script so the test
# follows the exact production code rather than a copy.

set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CLEANUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

if ! command -v wipefs >/dev/null 2>&1 || ! command -v mkfs.fat >/dev/null 2>&1; then
  echo "SKIP: wipefs or mkfs.fat not installed"
  exit 0
fi

# Extract the clear_signatures() function (plus nothing else) from the script.
FUNC=$(awk '/^clear_signatures\(\) \{/{p=1} p{print} p && /^}/{exit}' "$CLEANUP")
eval "$FUNC"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

IMG="$WORK/disk.img"
truncate -s 64M "$IMG"

failures=0
has_signature() { wipefs -J "$1" 2>/dev/null | grep -q '"type"'; }
check() {
  local label="$1" expected="$2" got=true
  has_signature "$IMG" || got=false
  if [[ $expected == "$got" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s\n' "$label"
    failures=$((failures + 1))
  fi
}

echo "==> a freshly written filesystem signature is wiped before reinstall"
mkfs.fat -F32 -n STALE "$IMG" >/dev/null 2>&1
check "stale signature present beforehand" "true"
clear_signatures "$IMG"
check "stale signature cleared by clear_signatures" "false"

echo "==> wiping an already-clean image is a no-op that still succeeds"
if clear_signatures "$IMG"; then
  printf '  ok   %s\n' "clean image returns 0"
else
  printf '  FAIL %s\n' "clean image returned non-zero"
  failures=$((failures + 1))
fi

echo "==> a busy/missing device fails loudly (call site tolerates it with || true)"
if clear_signatures "$WORK/does-not-exist"; then
  printf '  FAIL %s\n' "missing device returned 0 (should signal failure)"
  failures=$((failures + 1))
else
  printf '  ok   %s\n' "missing device returns non-zero (best-effort at call site)"
fi

# The production call site wraps each clear_signatures() in `|| true` so a busy
# device must never abort the install — assert that wrapping is actually present.
if grep -q 'clear_signatures "\$dev" || true' "$CLEANUP"; then
  printf '  ok   %s\n' "call site tolerates wipe failure with || true"
else
  printf '  FAIL %s\n' "call site does not tolerate wipe failure"
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
