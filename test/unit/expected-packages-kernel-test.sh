#!/bin/bash
#
# The installer's progress bar divides by the package count the build resolves
# for a target install: the root image's packages plus what the per-machine
# delta adds. The kernel an install gets is the build's OMARCHY_KERNEL on every
# architecture (the image carries it, so --needed adds nothing for it).
# Counting stock `linux` on x86_64 adds a kernel no install gets, and aborts
# the build the day the offline mirror stops carrying it.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work" /tmp/omarchy-expected-packages' EXIT

# The function alone, not the rest of the build.
awk '/^resolve_expected_packages\(\) \{$/,/^\}$/' "$ROOT/builder/build-iso.sh" >"$work/fn.sh"
[[ -s $work/fn.sh ]] || { echo "resolve_expected_packages not found in builder/build-iso.sh"; exit 1; }
source "$work/fn.sh"

# pacman resolves nothing new beyond what it is asked for, and records the ask.
pacman() {
  local arg print=false
  for arg; do [[ $arg == --print ]] && print=true; done
  $print || return 0
  printf '%s\n' "${@: -1}" >"$work/targets"
  printf '%s\n' "${@: -1}"
}

build_cache_dir=$work/cache
image_localdb=$work/localdb
mkdir -p "$build_cache_dir" "$image_localdb/local/base-3-3" "$image_localdb/local/mkinitcpio-40-1"
image_packages=(base mkinitcpio)

fail=0
for arch in x86_64 aarch64; do
  OMARCHY_ARCH=$arch OMARCHY_KERNEL=linux-omarchy
  count=$(resolve_expected_packages)
  asked=$(<"$work/targets")
  if [[ $asked != linux-omarchy ]]; then
    echo "$arch: the count resolves '$asked', not the kernel the install gets (linux-omarchy)"
    fail=1
  fi
  # Two image packages, the kernel, one microcode package.
  if [[ $count != 4 ]]; then
    echo "$arch: expected 4 packages, got $count"
    fail=1
  fi
done
(( fail == 0 )) || exit 1

echo "ok: the expected package count resolves the build's kernel on x86_64 and aarch64"
