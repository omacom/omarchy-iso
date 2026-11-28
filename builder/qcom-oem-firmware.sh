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

# Copy any qcom-firmware-extract/provided.d/*.list files shipped by the
# resolved Snapdragon OEM firmware packages into the live ISO. Only packages
# the install itself will bring are passed here, so provided.d cannot hide
# firmware for a package the install omits and huge linux-firmware-* archives
# are never scanned.
stage_live_qcom_provided_lists() {
  local target_airootfs=$1 here
  shift
  (( $# > 0 )) || return 0
  here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  python3 "$here/qualcomm/extract-firmware.py" provided-lists "$target_airootfs" "$@"
}
