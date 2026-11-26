#!/bin/bash
#
# The live initramfs's udev hook waits for the boot medium by UUID instead of
# settling the whole uevent queue. It must wait for what the archiso hook will
# look the medium up by, blkid, and not for udev's /dev/disk/by-uuid link.
#
# Booted from a Ventoy stick in normal mode it must not wait at all. Ventoy
# unpacks this initramfs under its own /ventoy scripts, and those map the ISO
# to /dev/mapper/ventoy only after every hook, just before archiso mounts it.
# A wait here can only time out: it held every 4.5.0rc3 normal-mode Ventoy boot
# for 50 s. GRUB2 mode, which puts rdinit=/vtoy/vtoy on the command line, maps
# it from the uevents the hook has just triggered, so there it still waits.
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

# run_case <name> <expected udevadm calls after trigger, then blkid looks>
#          <blkid finds it: yes|no> <Ventoy's /ventoy present: yes|no> [var=value ...]
run_case() {
  local name=$1 expected=$2 found=$3 ventoy=$4 calls
  shift 4
  rm -rf "$work/ventoy"
  [[ $ventoy == yes ]] && mkdir "$work/ventoy"
  calls=$(
    env -i PATH="$PATH" HOOK="$HOOK" WORK="$work" FOUND="$found" "$@" bash -c '
      : >"$WORK/calls"
      echo 0 >"$WORK/looks"
      msg() { :; }
      getarg() { [[ $1 == rdinit ]] && echo "${RDINIT:-}"; }
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
      # The hook looks for /ventoy; here it looks in the work directory.
      . <(sed "s|/ventoy|$WORK/ventoy|g" "$HOOK")
      run_hook
      echo "$(paste -sd" " "$WORK/calls")|$(<"$WORK/looks")"
    '
  )
  if [[ $calls == "$expected" ]]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: udevadm '$calls', expected '$expected'"
    failures=$((failures + 1))
  fi
}

run_case "a medium blkid finds, with no by-uuid link: no settle" "|3" yes no \
  archisosearchuuid=2026-10-27-12-53-28-00
run_case "a medium that never shows up: settle" "settle|300" no no \
  archisosearchuuid=2026-10-27-12-53-28-00
run_case "Ventoy's normal mode maps the medium after the hooks: no wait, no settle" "|0" no yes \
  archisosearchuuid=2026-10-27-12-53-28-00
run_case "Ventoy's GRUB2 mode maps it from the uevents: wait as usual" "|3" yes yes \
  archisosearchuuid=2026-10-27-12-53-28-00 RDINIT=/vtoy/vtoy
run_case "a PXE medium appears after the hooks: settle" "settle|0" yes no \
  archisosearchuuid=2026-10-27-12-53-28-00 archiso_nbd_srv=10.0.2.2
run_case "no UUID to wait for: settle" "settle|0" yes no

modules=$(bash -c '. "$1"; echo " ${MODULES[*]} "' _ "$CONF")
if [[ $modules == *" loop "* ]]; then
  echo "ok: the live initramfs loads loop"
else
  echo "FAIL: the live initramfs does not load loop (MODULES:$modules)"
  failures=$((failures + 1))
fi

((failures == 0)) || exit 1
