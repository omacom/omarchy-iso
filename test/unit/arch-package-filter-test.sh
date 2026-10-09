#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/builder/filter-packages.sh"

OMARCHY_ARCH_DROP=(intel-ucode linux-t2)
OMARCHY_ARCH_SUBST_FROM=(quickshell-git mise)
OMARCHY_ARCH_SUBST_TO=(quickshell mise-bin)
input=$'# packages\n\nintel-ucode\nlinux-t2\nquickshell-git\nmise\nlinux-aarch64\nintel-ucode-extra'

for ISO_ARCH in aarch64 x86_64; do
  if [[ $ISO_ARCH == aarch64 ]]; then
    expected=$'# packages\n\nquickshell\nmise-bin\nlinux-aarch64\nintel-ucode-extra'
  else
    expected=$input
  fi
  actual=$(printf '%s' "$input" | filter_arch_packages)
  [[ $actual == "$expected" ]] || {
    printf 'not ok - %s package filtering\n' "$ISO_ARCH" >&2
    exit 1
  }
  [[ $(printf '%s' "$actual" | filter_arch_packages) == "$actual" ]]
  [[ -z $(filter_arch_packages </dev/null) ]]
  printf 'ok - %s package filtering preserves comments, exact names and repeated input\n' "$ISO_ARCH"
done

# Exercise the shipped exclusions, not only the synthetic list above.
source "$ROOT/builder/filter-packages.sh"
input=$'dell-xps13-sidecar-amps\nbroadcom-wl\nbroadcom-wl-dkms\nlinux-aarch64'
input+=$'\napple-bcm-firmware-fetcher\nlinux-firmware-cirrus-dx13260\ngliff\nsuperwhisper-bin'
ISO_ARCH=aarch64
[[ $(printf '%s' "$input" | filter_arch_packages) == linux-aarch64 ]]
ISO_ARCH=x86_64
[[ $(printf '%s' "$input" | filter_arch_packages) == "$input" ]]
echo "ok - Dell, Broadcom, T2 firmware and x86-only application exclusions are ARM-only"
