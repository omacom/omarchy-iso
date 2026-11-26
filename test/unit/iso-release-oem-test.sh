#!/bin/bash
#
# omarchy-iso-release publishes the newest build of its architecture and
# channel in release/. An OEM build lands there under the same ending, and it
# erases the disk of whoever boots it without asking: a release must never
# pick one up, however new it is. The real script runs against a sandbox, as
# in iso-release-checksum-test.sh.

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

for ref in quattro rc; do
  printf 'the installer that asks\n' >"$sandbox/release/omarchy-2099.01.01-x86_64-$ref.iso"
  printf 'the installer that erases\n' >"$sandbox/release/omarchy-oem-2099.01.02-x86_64-$ref.iso"
  touch -d '2099-01-01' "$sandbox/release/omarchy-2099.01.01-x86_64-$ref.iso"
  touch -d '2099-01-02' "$sandbox/release/omarchy-oem-2099.01.02-x86_64-$ref.iso"
done

release 9.9.9 || fail "a release with an OEM build beside it still goes out"
[[ $(cat "$sandbox/release/omarchy-9.9.9-x86.iso") == "the installer that asks" ]] ||
  fail "a newer OEM build is never the one released" "$(cat "$sandbox/release/omarchy-9.9.9-x86.iso")"
grep -qx "$sandbox/release/omarchy-9.9.9-x86.iso" "$TEST_LOG" || fail "the release was not uploaded" "$(cat "$TEST_LOG")"

release --rc 9.9.9 || fail "a release candidate with an OEM build beside it still goes out"
[[ $(cat "$sandbox/release/omarchy-9.9.9-rc-x86.iso") == "the installer that asks" ]] ||
  fail "a newer OEM build is never the candidate released" "$(cat "$sandbox/release/omarchy-9.9.9-rc-x86.iso")"

echo "ok - a release publishes the interactive build, never a newer OEM one"

# With only an OEM build to hand there is nothing to release.
rm "$sandbox/release"/omarchy-2099.01.01-x86_64-*.iso "$sandbox/release"/omarchy-9.9.9-*
if release 9.9.8; then
  fail "a release went out with only an OEM build to take"
fi
[[ ! -e $sandbox/release/omarchy-9.9.8-x86.iso && ! -s $TEST_LOG ]] ||
  fail "a release with only an OEM build to take signed or uploaded something" "$(ls "$sandbox/release"; cat "$TEST_LOG")"

echo "ok - with only an OEM build in release/, nothing is released"
