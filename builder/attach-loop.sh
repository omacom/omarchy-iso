#!/bin/bash
# Attach IMAGE [--read-only] and print the device that cleanup should detach.
set -euo pipefail

image=$1
shift
# Docker populates its private /dev when the container starts. The kernel can
# allocate more loop devices later without creating their nodes in here.
if [[ ! -c /dev/loop-control ]]; then
  mknod /dev/loop-control c 10 237 || [[ -c /dev/loop-control ]]
fi

for ((attempt = 0; attempt < 16; attempt++)); do
  device=$(losetup --find)
  device=${device%% *} # losetup appends " (lost)" when the node is missing.
  if [[ ! $device =~ ^/dev/loop[0-9]+$ ]]; then
    echo "ERROR: unexpected loop device: $device" >&2
    exit 1
  fi
  if [[ ! -b $device ]]; then
    mknod "$device" b 7 "${device#/dev/loop}" || [[ -b $device ]]
  fi
  if error=$(losetup "$@" -- "$device" "$image" 2>&1); then
    printf '%s\n' "$device"
    exit 0
  fi
  # Retry only if another build claimed the free device before we attached.
  if [[ ! -e /sys/class/block/${device##*/}/loop/backing_file ]]; then
    printf '%s\n' "$error" >&2
    exit 1
  fi
done
echo "ERROR: could not acquire a loop device for $image" >&2
exit 1
