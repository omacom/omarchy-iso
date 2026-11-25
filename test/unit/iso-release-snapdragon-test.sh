#!/bin/bash
#
# The Snapdragon image is an aarch64 build of its own, released under its own
# name. A release of the plain aarch64 image must never pick up a newer
# Snapdragon build from release/, nor the other way round. The real script
# runs against a sandbox, as in iso-release-oem-test.sh.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

fail() {
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sandbox="$work/repo"
mkdir -p "$sandbox/bin" "$sandbox/release" "$work/stubs"
cp "$ROOT/bin/omarchy-iso-release" "$sandbox/bin/"

printf '#!/bin/bash\nprintf "signature\\n" >"$1.sig"\n' >"$work/stubs/omarchy-iso-sign"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >>"$TEST_LOG"\n' >"$work/stubs/omarchy-iso-upload"
chmod +x "$work/stubs"/*
export TEST_LOG="$work/uploads"

release() {
  : >"$TEST_LOG"
  PATH="$work/stubs:$PATH" "$sandbox/bin/omarchy-iso-release" --no-make "$@" >/dev/null 2>&1
}

printf 'plain\n' >"$sandbox/release/omarchy-2099.01.01-aarch64-quattro.iso"
printf 'snapdragon\n' >"$sandbox/release/omarchy-2099.01.01-aarch64-snapdragon-quattro.iso"
touch -d '2099-01-01' "$sandbox/release/omarchy-2099.01.01-aarch64-quattro.iso"
touch -d '2099-01-02' "$sandbox/release/omarchy-2099.01.01-aarch64-snapdragon-quattro.iso"

release --arch aarch64 9.9.9 || fail "the aarch64 release did not go out"
[[ $(cat "$sandbox/release/omarchy-9.9.9-aarch64.iso") == plain ]] ||
  fail "the aarch64 release took the newer Snapdragon build" "$(cat "$sandbox/release/omarchy-9.9.9-aarch64.iso")"
echo "ok - the aarch64 release publishes the plain build, never a newer Snapdragon one"

touch -d '2099-01-03' "$sandbox/release/omarchy-2099.01.01-aarch64-quattro.iso"
release --snapdragon 9.9.9 || fail "the Snapdragon release did not go out"
[[ $(cat "$sandbox/release/omarchy-9.9.9-snapdragon.iso") == snapdragon ]] ||
  fail "the Snapdragon release took the newer plain aarch64 build" "$(cat "$sandbox/release/omarchy-9.9.9-snapdragon.iso")"
grep -qx "$sandbox/release/omarchy-9.9.9-snapdragon.iso" "$TEST_LOG" || fail "the Snapdragon release was not uploaded" "$(cat "$TEST_LOG")"
echo "ok - the Snapdragon release publishes the Snapdragon build as omarchy-X.Y.Z-snapdragon.iso"

if release --snapdragon --arch x86_64 9.9.8; then
  fail "a Snapdragon release went out as x86_64"
fi
echo "ok - a Snapdragon release is always aarch64"
