#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/bin" "$work/repo/configs" "$work/repo/release" "$work/stubs" "$work/home" "$work/src" "$work/pkgs"
cp "$ROOT/bin/omarchy-iso-make" "$ROOT/bin/omarchy-iso-release" "$work/repo/bin/"
cp "$ROOT/configs/profiledef.sh" "$work/repo/configs/"

cat >"$work/stubs/git" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$work/stubs/omarchy-iso-sign" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$work/stubs/omarchy-iso-upload" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$work/stubs/docker" <<'STUB'
#!/bin/bash
if [[ $1 == "version" ]]; then
  exit 0
elif [[ $1 == "run" ]]; then
  printf '%s\n' "$@" >>"$TEST_DOCKER_LOG"
  printf 'fake iso\n' >"$TEST_RELEASE/omarchy-test-x86_64.iso"
fi
STUB

chmod +x "$work/stubs"/*
export TEST_DOCKER_LOG="$work/docker.log" TEST_RELEASE="$work/repo/release"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

run_make() {
  : >"$TEST_DOCKER_LOG"
  rm -f "$TEST_RELEASE"/*.iso
  (cd "$work/repo" && PATH="$work/stubs:$PATH" HOME="$work/home" \
    "$work/repo/bin/omarchy-iso-make" --no-boot-offer "$@") >"$work/output" 2>&1
}

# Default build keeps full compression and normal filename.
run_make || fail "default make failed"
grep -qxF -- 'OMARCHY_FAST_COMPRESSION=' "$TEST_DOCKER_LOG" || fail "default build did not leave OMARCHY_FAST_COMPRESSION empty"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-quattro.iso ]] || fail "default build did not write normal ISO name"
echo "ok - default build leaves OMARCHY_FAST_COMPRESSION unset and uses normal ISO name"

# --fast enables fast compression and tags the filename with -fast before the ref
# so release tooling ignores it while detect_packages still recognizes the ref.
run_make --edge --fast || fail "--fast make failed"
grep -qxF -- 'OMARCHY_FAST_COMPRESSION=1' "$TEST_DOCKER_LOG" || fail "--fast did not pass OMARCHY_FAST_COMPRESSION=1"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-fast-edge.iso ]] || fail "--fast did not tag ISO name with -fast-<ref>"
echo "ok - --fast passes OMARCHY_FAST_COMPRESSION=1 and names output -fast-<ref>.iso"

# --fast works on --rc and --rehearsal test builds, and omarchy-iso-release
# ignores newer -fast-<ref>.iso builds when selecting a release ISO.
run_make --rc --fast || fail "--fast --rc failed"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-fast-rc.iso ]] || fail "--fast --rc did not name output -fast-rc.iso"
run_make --local-source "$work/src" "$work/pkgs" --rehearsal --fast || fail "--fast --rehearsal failed"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-fast-rehearsal.iso ]] || fail "--fast --rehearsal did not name output -fast-rehearsal.iso"

rm -f "$TEST_RELEASE"/*.iso "$TEST_RELEASE"/*.sha256
printf 'normal-quattro\n' >"$TEST_RELEASE/omarchy-2026.11.24-x86_64-quattro.iso"
printf 'fast-quattro\n'   >"$TEST_RELEASE/omarchy-2026.11.25-x86_64-fast-quattro.iso"
touch -t 202611240000 "$TEST_RELEASE/omarchy-2026.11.24-x86_64-quattro.iso"
touch -t 202611250000 "$TEST_RELEASE/omarchy-2026.11.25-x86_64-fast-quattro.iso"
PATH="$work/stubs:$PATH" "$work/repo/bin/omarchy-iso-release" --no-make 4.5.0 >/dev/null || fail "omarchy-iso-release failed with normal + fast ISO"
[[ $(<"$TEST_RELEASE/omarchy-4.5.0-x86.iso") == "normal-quattro" ]] || fail "omarchy-iso-release picked the fast ISO over the normal ISO"

printf 'normal-rc\n' >"$TEST_RELEASE/omarchy-2026.11.24-x86_64-rc.iso"
printf 'fast-rc\n'   >"$TEST_RELEASE/omarchy-2026.11.25-x86_64-fast-rc.iso"
touch -t 202611240000 "$TEST_RELEASE/omarchy-2026.11.24-x86_64-rc.iso"
touch -t 202611250000 "$TEST_RELEASE/omarchy-2026.11.25-x86_64-fast-rc.iso"
PATH="$work/stubs:$PATH" "$work/repo/bin/omarchy-iso-release" --no-make --rc 4.5.0rc1 >/dev/null || fail "omarchy-iso-release --rc failed with normal + fast ISO"
[[ $(<"$TEST_RELEASE/omarchy-4.5.0rc1-x86.iso") == "normal-rc" ]] || fail "omarchy-iso-release --rc picked the fast ISO over the normal ISO"

rm -f "$TEST_RELEASE"/*.iso "$TEST_RELEASE"/*.sha256
printf 'fast-only\n' >"$TEST_RELEASE/omarchy-2026.11.25-x86_64-fast-quattro.iso"
if PATH="$work/stubs:$PATH" "$work/repo/bin/omarchy-iso-release" --no-make 4.5.0 >/dev/null 2>&1; then
  fail "omarchy-iso-release accepted a fast-only ISO"
fi
echo "ok - --fast works for rc/rehearsal tests and omarchy-iso-release ignores -fast-<ref>.iso"

# build-iso.sh exports OMARCHY_FAST_COMPRESSION to profiledef.sh.
grep -Eq '^export .*OMARCHY_FAST_COMPRESSION' "$ROOT/builder/build-iso.sh" || fail "build-iso.sh does not export OMARCHY_FAST_COMPRESSION"
echo "ok - build-iso.sh exports OMARCHY_FAST_COMPRESSION"

# profiledef.sh uses level 19 by default and level 1 when OMARCHY_FAST_COMPRESSION=1.
default_level=$(bash -c 'declare -A file_permissions=(); source "$1"; printf "%s\n" "${airootfs_image_tool_options[@]}"' _ "$ROOT/configs/profiledef.sh" | grep -A1 '^-Xcompression-level$' | tail -n1)
[[ $default_level == 19 ]] || fail "default squashfs compression level is $default_level, want 19"
fast_level=$(OMARCHY_FAST_COMPRESSION=1 bash -c 'declare -A file_permissions=(); source "$1"; printf "%s\n" "${airootfs_image_tool_options[@]}"' _ "$ROOT/configs/profiledef.sh" | grep -A1 '^-Xcompression-level$' | tail -n1)
[[ $fast_level == 1 ]] || fail "fast squashfs compression level is $fast_level, want 1"
echo "ok - profiledef.sh switches squashfs zstd level between 19 and 1"

# build-root-image.sh syntax and layer fast-mode compression.
bash -n "$ROOT/builder/build-root-image.sh" || fail "build-root-image.sh has a syntax error"
(
  eval "$(sed -n '/^layer_path() {$/,/^}$/p' "$ROOT/builder/build-root-image.sh")"
  eval "$(sed -n '/^write_layer() {$/,/^}$/p' "$ROOT/builder/build-root-image.sh")"
  output="$work/iso/omarchy-root.img.zst"
  mkdir -p "$work/iso" "$work/upper/etc"
  echo fast >"$work/upper/etc/test"
  OMARCHY_FAST_COMPRESSION=1 write_layer "$work/upper" aarch64-n1x >/dev/null
  [[ -s $(layer_path aarch64-n1x) ]]
  tar --zstd -tf "$(layer_path aarch64-n1x)" | grep -qxF './etc/test'
) || fail "write_layer failed under OMARCHY_FAST_COMPRESSION=1"
echo "ok - write_layer succeeds under OMARCHY_FAST_COMPRESSION=1"
