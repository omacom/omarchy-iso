#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILDER="$ROOT/builder/build-iso.sh"

hardware_line=$(grep '^hardware_packages=(' "$BUILDER")
hardware_list=${hardware_line#hardware_packages=(}
hardware_list=${hardware_list%)}

if tr ' ' '\n' <<<"$hardware_list" | grep -Fxq linux; then
  echo "stock linux must be part of the prebuilt root image, not the per-machine delta" >&2
  exit 1
fi
echo "ok: stock linux is baked into the default root image"

for package in linux-t2 amd-ucode intel-ucode sof-firmware alsa-firmware tailscale; do
  if ! tr ' ' '\n' <<<"$hardware_list" | grep -Fxq "$package"; then
    echo "$package must remain in the per-machine package set" >&2
    exit 1
  fi
done
echo "ok: alternate and hardware-specific packages remain per-machine"

grep -Fq 'qemu-img convert -c -q -f raw -O qcow2' "$ROOT/builder/build-root-image.sh"
grep -Fq 'cluster_size=1048576,lazy_refcounts=on,compression_type=zstd' \
  "$ROOT/builder/build-root-image.sh"
grep -Fq '((workers > 16)) && workers=16' "$ROOT/builder/build-root-image.sh"
if grep -F 'echo $(( image_count +' "$BUILDER" | grep -Fq '+ 1'; then
  echo "expected package count must not assume physical-CPU microcode in VMs" >&2
  exit 1
fi
grep -Fq 'btrfstune", "-f", "-u"' \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py"
grep -Fq '"btrfs", "filesystem", "resize", "max"' \
  "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py"
echo "ok: compact Btrfs qcow2 restores with a fresh UUID and grows to the target"

grep -Fq 'rm -f "$root_image_dir"/omarchy-root.*' "$BUILDER"
echo "ok: stale root-image representations cannot leak into the next ISO"
