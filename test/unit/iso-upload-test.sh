#!/bin/bash
#
# omarchy-iso-upload writes a published ISO once. iso.omarchy.org caches an
# ISO for a year, so other bytes under a published name would reach users
# beside a .sha256 and .sig that do not match them. This runs the real script
# with real rclone against a local remote and checks that a re-run of the same
# release passes, and that a re-spin under the same name is refused with
# nothing of it published.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
UPLOAD="$ROOT/bin/omarchy-iso-upload"

fails=0
check() { # desc, expected, actual
  if [[ $3 != "$2" ]]; then
    echo "FAIL: $1 (want '$2', got '$3')"; fails=1; return
  fi
  echo "ok: $1"
}

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT
export HOME=$BOX/home
mkdir -p "$HOME/.config/rclone" "$BOX/work" "$BOX/release"
# Omarchy:omarchy/ is a directory beside the working directory.
printf '[Omarchy]\ntype = local\n' >"$HOME/.config/rclone/rclone.conf"
cd "$BOX/work"

iso=$BOX/release/omarchy-9.9.9.iso
release() { # bytes, signature
  printf '%s' "$1" >"$iso"
  printf '%s  %s\n' "$(sha256sum "$iso" | cut -d' ' -f1)" "${iso##*/}" >"$iso.sha256"
  printf '%s' "$2" >"$iso.sig"
}
published() { cat "omarchy/$1" 2>/dev/null || echo missing; }
run() { "$UPLOAD" "$iso" >"$BOX/out" 2>&1 && echo 0 || echo $?; }

release "image-a" "signature-1"
check "a new release uploads" 0 "$(run)"
check "the ISO is published" "image-a" "$(published omarchy-9.9.9.iso)"
check "its signature is published" "signature-1" "$(published omarchy-9.9.9.iso.sig)"
sum_a=$(published omarchy-9.9.9.iso.sha256)

release "image-a" "signature-2"
check "a re-run of the same ISO, signed again, passes" 0 "$(run)"
check "the first signature stays" "signature-1" "$(published omarchy-9.9.9.iso.sig)"

release "image-b" "signature-3"
check "a re-spin under the same name is refused" 1 "$(run)"
check "the published ISO keeps its bytes" "image-a" "$(published omarchy-9.9.9.iso)"
check "its checksum stays" "$sum_a" "$(published omarchy-9.9.9.iso.sha256)"
check "its signature stays" "signature-1" "$(published omarchy-9.9.9.iso.sig)"
check "the refusal says to use a new name" 1 "$(grep -c 'new name' "$BOX/out")"

exit $fails
