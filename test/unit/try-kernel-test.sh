#!/bin/bash
#
# Try Omarchy runs the live kernel over the root image, so the two must carry
# the same kernel package (builder/try-kernel.sh). This runs check_try_kernel
# against pacman databases made for each case, and checks that build-iso.sh
# runs it for every build with a Try layer.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/builder/try-kernel.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# A pacman local database at $1 holding one package, $2 at version $3.
make_db() {
  local db=$1 name=$2 version=$3
  mkdir -p "$db/local/$name-$version"
  echo 9 >"$db/local/ALPM_DB_VERSION"
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n' "$name" "$version" >"$db/local/$name-$version/desc"
}

make_db "$fixture/live/var/lib/pacman" linux-omarchy 7.2.15-6
make_db "$fixture/image-same" linux-omarchy 7.2.15-6
make_db "$fixture/image-newer" linux-omarchy 7.2.15-7
make_db "$fixture/empty/var/lib/pacman" linux-t2 7.2.15.arch1-1

out=$(check_try_kernel "$fixture/live" "$fixture/image-same" linux-omarchy) ||
  fail "the same kernel in both was refused"
[[ $out == *"7.2.15-6"* ]] || fail "the passing check does not name the version: $out"
pass "the same kernel in the live system and the root image passes"

if err=$(check_try_kernel "$fixture/live" "$fixture/image-newer" linux-omarchy 2>&1); then
  fail "a live kernel without modules in the root image passed"
fi
[[ $err == *"7.2.15-6"*"7.2.15-7"* ]] || fail "the error does not name both versions: $err"
pass "a live kernel other than the root image's fails"

if check_try_kernel "$fixture/empty" "$fixture/image-same" linux-omarchy 2>/dev/null; then
  fail "a live system without the kernel package passed"
fi
pass "a live system without the kernel package fails"

build=$ROOT/builder/build-iso.sh
grep -Fqx 'source /builder/try-kernel.sh' "$build" || fail "build-iso.sh does not source try-kernel.sh"
# shellcheck disable=SC2016 # the call as written in build-iso.sh, unexpanded
grep -Fqx '  check_try_kernel "$build_cache_dir/work/$OMARCHY_ARCH/airootfs" "$image_localdb" "$OMARCHY_KERNEL" || exit 1' "$build" ||
  fail "build-iso.sh does not check the live kernel against the root image"
pass "build-iso.sh checks every build with a Try layer"
