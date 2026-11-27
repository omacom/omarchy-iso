#!/bin/bash

# The Snapdragon OEM firmware packages in the given sync databases: every
# package that provides a qcom-firmware-<folder> name, one per firmware folder
# a device tree loads from. Omarchy's install/hardware/qualcomm/oem-firmware.sh
# installs a machine's package by that name, so the offline mirror needs all of
# them, and finding them by what they provide keeps their names out of every
# package list.
qcom_oem_firmware_packages() {
  local db
  for db in "$@"; do
    bsdtar -xOf "$db" '*/desc'
  done | awk '
    /^%NAME%$/ { getline name }
    /^%PROVIDES%$/ {
      while ((getline line) > 0 && line != "")
        if (line ~ /^qcom-firmware-/) print name
    }
  ' | sort -u
}

# Copy any qcom-firmware-extract/provided.d/*.list files shipped by firmware
# packages in the offline mirror into the live ISO. That lets the live ISO's
# qcom-firmware-extract recognize board-packaged firmware even when a package
# predates the qcom-firmware-<folder> provides convention.
stage_live_qcom_provided_lists() {
  local mirror_dir=$1 target_airootfs=$2 pkg
  shopt -s nullglob
  for pkg in "$mirror_dir"/*-firmware-*.pkg.tar.*; do
    [[ $pkg == *.sig ]] && continue
    bsdtar -xf "$pkg" -C "$target_airootfs" --include='usr/share/qcom-firmware-extract/provided.d/*.list' 2>/dev/null || true
  done
  shopt -u nullglob
}
