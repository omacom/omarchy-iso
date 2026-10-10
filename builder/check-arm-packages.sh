#!/bin/bash
set -euo pipefail

# Check the packages actually going into the offline mirror, including local builds.
media_target=$1
runtime_package=$2
settings_package=$3

case "$media_target" in
  aarch64/snapdragon|aarch64/generic) ;;
  *) echo "Unsupported ARM media target: $media_target" >&2; exit 1 ;;
esac

runtime_files=$(bsdtar -tf "$runtime_package" | sed 's|^\./||')
settings_files=$(bsdtar -tf "$settings_package" | sed 's|^\./||')

require_file() {
  local package=$1 files=$2 path=$3
  if ! grep -Fxq "$path" <<< "$files"; then
    echo "ERROR: ${package##*/} is missing $path required by $media_target" >&2
    echo "Publish compatible ARM packages to the selected channel, or supply them with --local-repo/--local-source." >&2
    exit 1
  fi
}

for path in \
  etc/mkinitcpio.conf.d/omarchy_hooks.conf \
  etc/limine-entry-tool.d/omarchy-defaults.conf \
  etc/limine-entry-tool.d/omarchy-uki.conf \
  usr/share/omarchy/default/limine/limine.conf; do
  require_file "$settings_package" "$settings_files" "$path"
done

if [[ $media_target == aarch64/snapdragon ]]; then
  for path in \
    usr/share/omarchy/install/hardware/qualcomm/dtb-uki.sh \
    usr/share/omarchy/install/hardware/qualcomm/firmware.sh \
    usr/share/omarchy/install/hardware/qualcomm/kernel-params.sh; do
    require_file "$runtime_package" "$runtime_files" "$path"
  done
  for path in \
    usr/share/omarchy/default/pacman/pacman-aarch64.conf \
    usr/share/omarchy/default/pacman/mirrorlist-aarch64; do
    require_file "$settings_package" "$settings_files" "$path"
  done
fi
