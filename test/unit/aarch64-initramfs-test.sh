#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
preset=$(awk '
  /^cat > \/etc\/mkinitcpio.d\/linux-aarch64.preset <</ { inside = 1; next }
  inside && /^PRESET$/ { exit }
  inside { print }
' "$ROOT/configs/aarch64/customize_airootfs.sh")
[[ -n $preset ]]
eval "$preset"
[[ ${PRESETS[*]} == archiso ]]
[[ $archiso_image == /boot/initramfs-linux-aarch64.img ]]
# A preset-specific config makes mkinitcpio skip all drop-ins.
[[ ! -v ALL_config && ! -v archiso_config ]]

source "$ROOT/configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
# Model the installed-system settings that precede the live override.
HOOKS=(base udev plymouth encrypt filesystems)
MODULES=(thunderbolt i2c_hid_of)
source "$ROOT/configs/aarch64/zz-aarch64-live.conf"
for hook in archiso archiso_loop_mnt plymouth keyboard filesystems; do
  [[ " ${HOOKS[*]} " == *" $hook "* ]]
done
for hook in microcode memdisk encrypt; do
  [[ " ${HOOKS[*]} " != *" $hook "* ]]
done
[[ ${MODULES[*]} == i2c_hid_of ]]
echo "ok - aarch64 live preset preserves drop-ins and excludes x86 and installed-root hooks"
