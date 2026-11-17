#!/bin/bash
#
# An x86_64 build whose repositories do not offer every T2 Mac package must
# stop, not warn and ship an image without them.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/builder/required-packages.sh"
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

all=$(printf '%s\n' git linux-omarchy linux-t2 linux-t2-headers apple-t2-audio-config apple-bcm-firmware-fetcher t2fanrd)
check "x86_64 with every T2 package: nothing missing" "" "$(missing_required_packages x86_64 <<<"$all")"
check "x86_64 without t2fanrd: t2fanrd missing" "t2fanrd" "$(missing_required_packages x86_64 <<<"$(grep -vx t2fanrd <<<"$all")")"
check "x86_64 with only a prefix of a name: still missing" "linux-t2" \
  "$(missing_required_packages x86_64 <<<"$(grep -vx linux-t2 <<<"$all"; echo linux-t2-docs)")"
check "aarch64 needs none of them" "" "$(missing_required_packages aarch64 <<<"git")"

grep -Fq 'source /builder/required-packages.sh' "$ROOT/builder/build-iso.sh" ||
  check "build-iso.sh sources the check" "sourced" "not sourced"
# shellcheck disable=SC2016 # the literal call in build-iso.sh
grep -Fq 'missing_required_packages "$OMARCHY_ARCH"' "$ROOT/builder/build-iso.sh" ||
  check "build-iso.sh runs the check" "runs" "does not run"

(( failures == 0 )) || exit 1
