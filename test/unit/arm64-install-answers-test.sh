#!/bin/bash
#
# test/arm64-install borrows build_cidata from the x86_64 harness, so the two
# cannot drift apart. That only holds if it also has every setting the
# borrowed function reads: under set -u a missing one stops the aarch64
# install test before its VM starts. Run its answers block here, on any host,
# the way it runs there.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$ROOT/test/arm64-install"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# From the answers header to the call that reads the ISO, which needs a real
# one; what that call sets is given below.
answers=$(sed -n '/^# --- answers/,/^ISO=\$iso detect_packages$/p' "$script" | sed '$d')
[[ -n $answers ]] || fail "arm64-install has no answers block before detect_packages"

# What only the image needs: CI's unit container has no mtools or dosfstools.
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/mkfs.vfat"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/mcopy"
chmod +x "$work/bin/mkfs.vfat" "$work/bin/mcopy"

(
  set -u
  PATH="$work/bin:$PATH"
  state=$work iso=/nonexistent.iso
  eval "$answers"
  RUNTIME_PACKAGE=omarchy SETTINGS_PACKAGE=omarchy-settings
  build_cidata >"$work/build.log" 2>&1
) || fail "build_cidata does not run with arm64-install's settings: $(tail -n2 "$work/build.log" 2>/dev/null)"

config=$work/cidata/user_configuration.json
jq -e . "$config" >/dev/null || fail "build_cidata wrote no valid user_configuration.json"
echo "ok - arm64-install gives build_cidata every setting it reads"

# The answers describe the disk the VM is given: the same size on both sides.
disk_gb=$(sed -n 's/^qemu-img create -q -f qcow2 "\$state\/target.qcow2" "\${\([A-Z_]*\)}G"$/\1/p' "$script")
[[ $disk_gb == DISK_GB ]] || fail "arm64-install's target disk is not sized by DISK_GB, the size the answers are built for"
echo "ok - the VM's disk is the size the answers were built for"
