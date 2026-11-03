#!/bin/bash
#
# omarchy-iso-boot-pxe keeps its VM disk and the TFTP root the guest boots
# from in one work directory, and qemu-img create truncates whatever path it
# is handed. A directory someone else made first, or one others can write to,
# could hold a disk.qcow2 symlink to one of our files or a kernel of their
# choosing. private_work_dir is the gate: it creates the directory 0700 or
# accepts only one that is already ours alone.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/bin/lib/netboot.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # desc, expected_rc, dir, [disk]
  local desc=$1 want=$2 got=0
  private_work_dir "$3" "${4:-$3/disk.qcow2}" 2>/dev/null || got=$?
  if [[ $want == 0 && $got != 0 ]] || [[ $want != 0 && $got == 0 ]]; then
    echo "FAIL: $desc (rc want=$want got=$got)"; fails=1; return
  fi
  echo "ok: $desc"
}

fresh="$work/cache/omarchy-iso-boot-pxe"
check "a missing work directory is created" 0 "$fresh"
if [[ $(stat -c %a "$fresh" 2>/dev/null) != 700 ]]; then
  echo "FAIL: a new work directory is private (mode $(stat -c %a "$fresh" 2>/dev/null))"; fails=1
else
  echo "ok: a new work directory is private"
fi

: >"$fresh/disk.qcow2"
check "our own directory with a disk is reused" 0 "$fresh"

mkdir -m 755 "$work/open"
chmod 777 "$work/open"
check "a world-writable directory is refused" 1 "$work/open"

mkdir -m 770 "$work/group"
check "a group-writable directory is refused" 1 "$work/group"

ln -s "$fresh" "$work/link"
check "a symlinked work directory is refused" 1 "$work/link"

mkdir -m 700 "$work/planted"
: >"$work/victim"
ln -s "$work/victim" "$work/planted/disk.qcow2"
check "a symlinked disk is refused" 1 "$work/planted"

# Someone else's directory: chown one when we can, else any root-owned one.
if ((EUID == 0)); then
  mkdir -m 755 "$work/foreign"
  chown 65534:65534 "$work/foreign"
  foreign="$work/foreign"
else
  foreign=/
fi
check "a directory owned by someone else is refused" 1 "$foreign" "$work/unused.qcow2"

((fails == 0))
