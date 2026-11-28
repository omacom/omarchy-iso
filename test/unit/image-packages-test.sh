#!/bin/bash
#
# The root image holds what every install gets. Audio firmware and Tailscale
# go only to the machines that need them: archinstall's audio step adds the
# firmware by the loaded sound driver, and Tailscale comes with an autoinstall
# auth key. In the image they land on every disk, and every update downloads
# them again. Both microcodes stay: a pre-built UKI, where the image has one,
# bundles both, so every machine early-loads its own on first boot.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The selection alone, not the rest of the build, reading this checkout's
# lists where the builder container mounts them at /builder.
{
  grep '^per_machine_packages=' "$ROOT/builder/build-iso.sh"
  awk '/^image_package_list\(\) \{$/,/^\}$/' "$ROOT/builder/build-iso.sh"
} | sed "s#/builder/#$ROOT/builder/#g" >"$work/fn.sh"
grep -q '^image_package_list() {' "$work/fn.sh" || { echo "image_package_list not found in builder/build-iso.sh"; exit 1; }
# shellcheck source=/dev/null # the function this test just took out of the builder
source "$work/fn.sh"

archinstall_packages_file=$ROOT/builder/archinstall.packages
build_cache_dir=$work/cache
mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
printf '%s\n' hyprland snapper >"$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
# shellcheck disable=SC2034 # read by image_package_list, taken out of the builder
image_arch_packages=()
# shellcheck disable=SC2034 # as above
OMARCHY_RUNTIME_PACKAGE=omarchy OMARCHY_SETTINGS_PACKAGE=omarchy-settings OMARCHY_NVIM_PACKAGE=omarchy-nvim

mapfile -t image < <(image_package_list)
has() { printf '%s\n' "${image[@]}" | grep -qxF "$1"; }

fail=0
for pkg in alsa-firmware sof-firmware tailscale; do
  if has "$pkg"; then
    echo "the image holds $pkg, which only some machines get"
    fail=1
  fi
  # The shipped mirror is the closure of the lists an install can ask for,
  # archinstall.packages among them, less what the image holds.
  if ! grep -qxF "$pkg" "$archinstall_packages_file"; then
    echo "archinstall.packages no longer names $pkg, so the shipped mirror would lose it"
    fail=1
  fi
done
for pkg in amd-ucode intel-ucode linux-omarchy linux-omarchy-headers base linux-firmware hyprland omarchy; do
  has "$pkg" || { echo "the image lacks $pkg, which every install gets"; fail=1; }
done
(( fail == 0 )) || exit 1

echo "ok: the image leaves the audio firmware and Tailscale to the machines that need them"

# A Snapdragon ISO installs Snapdragon laptops only, so its root image bakes in
# the Qualcomm default set instead of pacstrapping it at install time.
printf '%s\n' hyprland snapper linux-firmware-qcom qcom-firmware-extract >"$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.aarch64-qualcomm.packages"
mapfile -t snapdragon_image < <(OMARCHY_SNAPDRAGON=1 image_package_list)
for pkg in linux-firmware-qcom qcom-firmware-extract; do
  printf '%s\n' "${snapdragon_image[@]}" | grep -qxF "$pkg" || {
    echo "the Snapdragon image lacks $pkg from omarchy-base.aarch64-qualcomm.packages"
    exit 1
  }
done
echo "ok: the Snapdragon image bakes in the Qualcomm default package set"
