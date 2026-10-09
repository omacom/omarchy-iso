#!/bin/bash
#
# Runs inside the live root while mkarchiso builds it, after the live packages
# were pacstrapped from the bundled mirror. Drop the package files the root
# image already provides (build-iso.sh lists what to keep); nothing at install
# time can download them, since the same versions are installed from the
# image. The repo db is left complete so `pacman -S --needed` over package
# lists that mix image packages with new ones still resolves every name.

set -euo pipefail

# Stamp the ConditionNeedsUpdate= markers before anything below can exit early.
# pacstrap leaves /etc newer than the ld.so.cache, the journal catalog and the
# sysusers stamp it just wrote, so on every live boot systemd re-runs
# ldconfig.service, systemd-journal-catalog-update.service and
# systemd-sysusers.service against a read-only squashfs that cannot have
# changed since it was built. Measured on the live ISO: "Rebuild Dynamic Linker
# Cache" takes 403 ms, plus the catalog and sysusers runs.
#
# The installer does the same for the installed system. systemd-update-done
# is not in PATH: systemd ships it under /usr/lib/systemd, which is where the
# installer calls it from in the target too. If it is missing, the systemd
# layout is unexpected and live boots redo the work: slower, but not a build
# failure, so warn instead of failing.
if [[ -x /usr/lib/systemd/systemd-update-done ]]; then
  /usr/lib/systemd/systemd-update-done
  echo "Stamped /etc/.updated and /var/.updated; live boots skip ldconfig, the journal catalog and sysusers."
else
  echo "WARNING: /usr/lib/systemd/systemd-update-done missing; every live boot will redo the update units" >&2
fi

# The live system installs from the stick and never joins a network on its
# own: the configurator has no Wi-Fi step, and the one network call it makes
# (tzupdate, for a timezone guess) only works over a cable that is already
# plugged in. So firmware for radios, datacenter NICs, cameras and ARM SoCs is
# 330 MB of ISO that no driver in this system can ask for. What stays is
# everything a machine may need to show the installer and speak it: GPU
# firmware (a GPU driver that fails for want of firmware has already taken the
# screen from the firmware framebuffer, and nouveau needs nvidia/ for GSP),
# audio (the accessibility entry speaks), microcode, and wired NICs.
# The installed system gets its firmware from the root image, not from here.
fw=/usr/lib/firmware
if [[ -d $fw ]]; then
  before=$(du -sm "$fw" | cut -f1)
  rm -rf "$fw"/intel/iwlwifi "$fw"/intel/ibt-* "$fw"/iwlwifi-* \
    "$fw"/mediatek "$fw"/mrvl "$fw"/ath[0-9]* "$fw"/ar3k "$fw"/brcm "$fw"/cypress \
    "$fw"/rtw88 "$fw"/rtw89 "$fw"/rtlwifi "$fw"/rtl_bt "$fw"/ti-connectivity "$fw"/qca \
    "$fw"/nxp "$fw"/libertas "$fw"/mwl8k "$fw"/mwlwifi "$fw"/airoha "$fw"/qcom \
    "$fw"/wfx "$fw"/rsi "$fw"/mt76* "$fw"/mt79* \
    "$fw"/dpaa2 "$fw"/cxgb3 "$fw"/cxgb4 "$fw"/mellanox "$fw"/netronome "$fw"/liquidio \
    "$fw"/qed "$fw"/cavium "$fw"/intel/ice \
    "$fw"/dvb-* "$fw"/v4l-* "$fw"/intel/ipu* "$fw"/intel/vsc "$fw"/intel/irci* \
    "$fw"/imx "$fw"/meson "$fw"/rockchip "$fw"/arm "$fw"/powervr "$fw"/nvidia/tegra* \
    "$fw"/amlogic "$fw"/cnm "$fw"/cadence "$fw"/ti-keystone "$fw"/microchip
  echo "Live firmware: ${before} MB -> $(du -sm "$fw" | cut -f1) MB (no radio, datacenter NIC, camera or SoC firmware)."
fi

# Nobody reads documentation or compiles against headers in the installer, and
# it speaks English only.
rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc /usr/share/gir-1.0 /usr/include
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name locale.alias -exec rm -rf {} +

mirror=/var/cache/omarchy/mirror/offline
shipped_list=/usr/share/omarchy-iso/offline-mirror.shipped

[[ -f $shipped_list && -d $mirror ]] || exit 0

declare -A shipped=()
while IFS= read -r filename; do
  [[ -n $filename ]] && shipped["$filename"]=1
done <"$shipped_list"

if (( ${#shipped[@]} == 0 )); then
  echo "ERROR: refusing to prune the shipped mirror with an empty selection" >&2
  exit 1
fi
for filename in "${!shipped[@]}"; do
  if [[ ! -f $mirror/$filename ]]; then
    echo "ERROR: shipped mirror selection names a missing package: $filename" >&2
    exit 1
  fi
done

removed=0
for path in "$mirror"/*.pkg.tar.*; do
  filename=${path##*/}
  [[ $filename == *.sig ]] && continue
  [[ -n ${shipped[$filename]+x} ]] && continue
  rm -f -- "$path" "$path.sig"
  removed=$((removed + 1))
done
echo "Removed $removed package files the root image already provides; ${#shipped[@]} remain."
