#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/bin" "$work/repo/configs" "$work/repo/release" "$work/stubs" "$work/home" "$work/src" "$work/pkgs"
cp "$ROOT/bin/omarchy-iso-make" "$work/repo/bin/"
cp "$ROOT/configs/profiledef.sh" "$work/repo/configs/"

cat >"$work/stubs/git" <<'STUB'
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

# --fast works on --rc and --rehearsal test builds, and omarchy-iso-release's
# release glob never matches a -fast-<ref>.iso.
run_make --rc --fast || fail "--fast --rc failed"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-fast-rc.iso ]] || fail "--fast --rc did not name output -fast-rc.iso"
run_make --local-source "$work/src" "$work/pkgs" --rehearsal --fast || fail "--fast --rehearsal failed"
[[ -f $TEST_RELEASE/omarchy-test-x86_64-fast-rehearsal.iso ]] || fail "--fast --rehearsal did not name output -fast-rehearsal.iso"

for ref in quattro rc; do
  name="omarchy-2026.11.25-x86_64-fast-$ref.iso"
  if [[ $name == omarchy-[0-9]*"x86_64-$ref".iso ]]; then
    fail "omarchy-iso-release glob would match $name"
  fi
done
echo "ok - --fast works for rc/rehearsal tests and is excluded from omarchy-iso-release's glob"

# build-iso.sh exports OMARCHY_FAST_COMPRESSION to profiledef.sh.
grep -Eq '^export .*OMARCHY_FAST_COMPRESSION' "$ROOT/builder/build-iso.sh" || fail "build-iso.sh does not export OMARCHY_FAST_COMPRESSION"
echo "ok - build-iso.sh exports OMARCHY_FAST_COMPRESSION"

# profiledef.sh uses level 19 by default and level 1 when OMARCHY_FAST_COMPRESSION=1.
default_level=$(bash -c 'declare -A file_permissions=(); source "$1"; printf "%s\n" "${airootfs_image_tool_options[@]}"' _ "$ROOT/configs/profiledef.sh" | grep -A1 '^-Xcompression-level$' | tail -n1)
[[ $default_level == 19 ]] || fail "default squashfs compression level is $default_level, want 19"
fast_level=$(OMARCHY_FAST_COMPRESSION=1 bash -c 'declare -A file_permissions=(); source "$1"; printf "%s\n" "${airootfs_image_tool_options[@]}"' _ "$ROOT/configs/profiledef.sh" | grep -A1 '^-Xcompression-level$' | tail -n1)
[[ $fast_level == 1 ]] || fail "fast squashfs compression level is $fast_level, want 1"
echo "ok - profiledef.sh switches squashfs zstd level between 19 and 1"

# build-root-image.sh syntax and N1x layer fast-mode compression.
bash -n "$ROOT/builder/build-root-image.sh" || fail "build-root-image.sh has a syntax error"
(
  eval "$(sed -n '/^n1x_layer_path() {$/,/^}$/p' "$ROOT/builder/build-root-image.sh")"
  eval "$(sed -n '/^write_n1x_layer() {$/,/^}$/p' "$ROOT/builder/build-root-image.sh")"
  output="$work/iso/omarchy-root.img.zst"
  mkdir -p "$work/iso" "$work/upper/etc"
  echo fast >"$work/upper/etc/test"
  OMARCHY_FAST_COMPRESSION=1 write_n1x_layer "$work/upper" >/dev/null
  [[ -s $(n1x_layer_path) ]]
  tar --zstd -tf "$(n1x_layer_path)" | grep -qxF './etc/test'
) || fail "write_n1x_layer failed under OMARCHY_FAST_COMPRESSION=1"
echo "ok - write_n1x_layer succeeds under OMARCHY_FAST_COMPRESSION=1"
