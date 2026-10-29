#!/bin/bash
#
# The live initramfs's udev hook waits for the boot medium by UUID instead of
# settling the whole uevent queue. It must wait for what the archiso hook will
# look the medium up by, blkid, and not for udev's /dev/disk/by-uuid link.
# Ventoy boots the ISO as a file on its stick and maps it to
# /dev/mapper/ventoy with dmsetup from a udev rule, once the stick has been
# scanned; that device never gets the link. Waiting for the link ran out its
# 30 s on every Ventoy boot of 4.5.0rc2, and without that delay archiso
# searched before the map existed, mounted the stick's VTOYEFI partition
# and dropped to a shell behind the Plymouth splash.
#
# The hook runs with udevadm, blkid and sleep stubbed: the medium shows up
# to blkid on its third look, and udev never makes a by-uuid link for it.
# The live initramfs also loads loop itself: under Ventoy there is no
# /dev/loop-control node for losetup to autoload it through.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/configs/airootfs/etc/initcpio/hooks/udev"
CONF="$ROOT/configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# run_case <name> <expected udevadm calls after trigger> <blkid finds it: yes|no> [var=value ...]
run_case() {
  local name=$1 expected=$2 found=$3 calls
  shift 3
  calls=$(
    env -i PATH="$PATH" HOOK="$HOOK" WORK="$work" FOUND="$found" "$@" bash -c '
      : >"$WORK/calls"
      echo 0 >"$WORK/looks"
      msg() { :; }
      sleep() { :; }
      udevadm() {
        [[ $1 == trigger ]] && return 0
        echo "$1" >>"$WORK/calls"
        # No by-uuid link ever appears, as for Ventoy'"'"'s device-mapper disk.
        [[ $1 == wait ]] && return 1
        return 0
      }
      blkid() {
        local looks=$(($(<"$WORK/looks") + 1))
        echo "$looks" >"$WORK/looks"
        [[ $FOUND == yes ]] && ((looks >= 3))
      }
      archisosearchuuid=${archisosearchuuid:-}
      archiso_nbd_srv=${archiso_nbd_srv:-} archiso_nfs_srv=${archiso_nfs_srv:-} archiso_http_srv=${archiso_http_srv:-}
      . "$HOOK"
      run_hook
      paste -sd" " "$WORK/calls"
    '
  )
  if [[ $calls == "$expected" ]]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: udevadm '$calls', expected '$expected'"
    failures=$((failures + 1))
  fi
}

run_case "a medium blkid finds, with no by-uuid link (Ventoy): no settle" "" yes \
  archisosearchuuid=2026-10-27-12-53-28-00
run_case "a medium that never shows up: settle" "settle" no \
  archisosearchuuid=2026-10-27-12-53-28-00
run_case "a PXE medium appears after the hooks: settle" "settle" yes \
  archisosearchuuid=2026-10-27-12-53-28-00 archiso_nbd_srv=10.0.2.2
run_case "no UUID to wait for: settle" "settle" yes

modules=$(bash -c '. "$1"; echo " ${MODULES[*]} "' _ "$CONF")
if [[ $modules == *" loop "* ]]; then
  echo "ok: the live initramfs loads loop"
else
  echo "FAIL: the live initramfs does not load loop (MODULES:$modules)"
  failures=$((failures + 1))
fi

((failures == 0)) || exit 1
