#!/bin/bash
#
# Runs inside the live root while mkarchiso builds it, after the live packages
# were pacstrapped from the bundled mirror. Drop the package files the root
# image already provides (build-iso.sh lists what to keep); nothing at install
# time can download them, since the same versions are installed from the
# image. The repo db is left complete so `pacman -S --needed` over package
# lists that mix image packages with new ones still resolves every name.

set -euo pipefail

# >>> no plymouth (x86_64; builder/build-iso.sh takes this block out for aarch64)
# The live boot has no early KMS, so Plymouth drew only on UEFI's firmware
# framebuffer for a second or two and blanked a BIOS machine's text console;
# etc/initcpio/hooks/omarchy-logo covers both now. The package is pulled in
# by omarchy-settings, and leaving it installed leaves its units for systemd
# to list: remove it outright, dependency record and all, with its config.
if pacman -Qq plymouth >/dev/null 2>&1; then
  pacman -Rdd --noconfirm plymouth >/dev/null
  rm -rf /etc/plymouth
  echo "Plymouth removed from the live image."
fi
# <<< no plymouth

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
# qcom/ goes too, Adreno's included: msm keeps the display without it and
# loads the GPU's microcode only when the DRM device is first opened
# (msm_open -> load_gpu in drivers/gpu/drm/msm/msm_drv.c), which the installer,
# a TUI on fbcon, never does. The DSP firmware a Snapdragon live boot needs
# before the medium appears is in its UKI's own initramfs, which build-iso.sh
# has this script build before it gets here.
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

# The vendor and model name tables are left out of udev's hwdb by the pacman
# hook etc/pacman.d/hooks/60-omarchy-live-hwdb.hook, during the pacstrap so
# the live initramfs gets the small hwdb.bin too; check that it ran.
hwdb_kb=$(du -k /usr/lib/udev/hwdb.bin 2>/dev/null | cut -f1)
if [[ -e /usr/lib/udev/hwdb.d/20-pci-vendor-model.hwdb ]]; then
  echo "WARNING: the live hwdb still carries the vendor/model name tables (hwdb.bin ${hwdb_kb:-?} KB); 60-omarchy-live-hwdb.hook did not run" >&2
else
  echo "Live udev hwdb.bin: ${hwdb_kb:-?} KB (no vendor/model name tables)."
fi

# The console logo (the greeter's and a copy fitted to 80 columns, with their
# widths) is written by the pacman hook etc/pacman.d/hooks/60-omarchy-live-
# logo.hook, during the pacstrap so the live initramfs gets it too; check
# that it ran and that the fitted one fits.
console_logo=/usr/share/omarchy-iso/console-logo
if [[ -s $console_logo/fitted.txt && -s $console_logo/greeter.txt ]]; then
  fitted_columns=$(LC_ALL=C.UTF-8 awk '{ if (length > max) max = length } END { print max+0 }' "$console_logo/fitted.txt")
  greeter_columns=$(LC_ALL=C.UTF-8 awk '{ if (length > max) max = length } END { print max+0 }' "$console_logo/greeter.txt")
  if (( fitted_columns > 80 )); then
    echo "WARNING: $console_logo/fitted.txt is $fitted_columns columns wide and wraps on a VGA text console" >&2
  elif [[ $(cat "$console_logo/fitted.cols" 2>/dev/null) != "$fitted_columns" || $(cat "$console_logo/greeter.cols" 2>/dev/null) != "$greeter_columns" ]]; then
    echo "WARNING: the widths in $console_logo/*.cols are wrong; the boot logo would not sit where the greeter draws" >&2
  else
    echo "Console logo: $greeter_columns columns, $fitted_columns for the VGA console."
  fi
else
  echo "WARNING: $console_logo is incomplete; 60-omarchy-live-logo.hook did not run, the live boot shows no logo before the greeter" >&2
fi

# The squashfs lays the files in usr/share/omarchy-iso/boot-files.sort out
# first (builder/build-iso.sh); a package update renames what it names, so
# count what is left of it.
boot_files_sort=/usr/share/omarchy-iso/boot-files.sort
listed=0; missing=0
while IFS= read -r line; do
  [[ -n $line && $line != \#* ]] || continue
  path=${line% *}             # the priority comes last
  path=${path//\\\\/\\}        # a backslash in a name is written \\
  path=${path//\\ / }         # a space, "\ "
  listed=$((listed + 1))
  [[ -e /$path ]] || missing=$((missing + 1))
done <"$boot_files_sort"
if (( listed == 0 )); then
  echo "WARNING: $boot_files_sort lists nothing; the boot's files are laid out as mksquashfs finds them" >&2
elif (( missing * 10 > listed )); then
  echo "WARNING: $missing of the $listed files in $boot_files_sort are not in this image; regenerate it with bin/omarchy-iso-boot-files" >&2
else
  echo "Boot file layout: $((listed - missing)) of $listed listed files present."
fi

# The live console font (Terminus plus the half blocks the logo needs), built
# here so the installer loads it with setfont alone instead of starting Python
# on the medium first (i18n_console_font in /usr/share/omarchy-iso/i18n.sh).
for size in 16 32; do
  python3 /usr/share/omarchy-iso/console-font.py \
    "/usr/share/kbd/consolefonts/ter-v${size}b.psf.gz" "/usr/share/omarchy-iso/console-$size.psf" ||
    echo "WARNING: console-$size.psf not built; the live installer will generate it at boot" >&2
done

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
