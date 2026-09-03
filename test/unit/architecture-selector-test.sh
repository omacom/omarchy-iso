#!/bin/bash
#
# Unit tests for the --arch flag of omarchy-iso-make: which container image,
# platform, and OMARCHY_ARCH the build runs with, and how the ISO is named.
# docker and git are stubbed; the script itself runs for real from a sandbox
# copy of the repo so nothing lands in the real release/ directory.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# omarchy-iso-make resolves release/ and the mounts from its own location and
# lints configs/ from the working directory, so give it a sandbox repo.
sandbox="$work/repo"
mkdir -p "$sandbox/bin" "$work/stubs"
cp "$ROOT/bin/omarchy-iso-make" "$sandbox/bin/"
cp -R "$ROOT/builder" "$ROOT/configs" "$sandbox/"
mkdir -p "$sandbox/archiso"

# The stub records its argument list, then produces the ISO mkarchiso would
# have written into /out/, named after the architecture like profiledef does.
cat >"$work/stubs/docker" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == version ]] && exit 0
printf '%s\n' "$@" >"$TEST_DOCKER_ARGS"
arch="" out="" previous=""
for argument in "$@"; do
  if [[ $previous == "-e" && $argument == OMARCHY_ARCH=* ]]; then
    arch="${argument#*=}"
  elif [[ $previous == "-v" && $argument == *:/out/ ]]; then
    out="${argument%:/out/}"
  fi
  previous="$argument"
done
[[ -n $arch && -n $out ]]
touch "$out/omarchy-test-$arch.iso"
STUB

cat >"$work/stubs/git" <<'STUB'
#!/bin/bash
# No submodule to update and no index to consult in the sandbox.
exit 0
STUB
chmod +x "$work/stubs/docker" "$work/stubs/git"

# The script's permissions lint uses grep -P; on a BSD host borrow GNU grep.
if ! grep -qP 'x' <<<"x" 2>/dev/null && command -v ggrep >/dev/null; then
  ln -s "$(command -v ggrep)" "$work/stubs/grep"
fi

run_make() {
  local label="$1"
  shift
  export TEST_DOCKER_ARGS="$work/docker-$label.args"
  (
    cd "$sandbox"
    PATH="$work/stubs:$PATH" HOME="$work/home" \
      "$BASH" bin/omarchy-iso-make "$@" --keep-pkg-cache --no-cache --no-boot-offer >/dev/null
  )
}

assert_arg() {
  local file="$1"
  local expected="$2"

  grep -qxF -- "$expected" "$file" ||
    fail "docker argument $expected" "$(printf 'arguments were:\n'; cat "$file")"
}

refute_arg() {
  local file="$1"
  local unexpected="$2"

  if grep -qxF -- "$unexpected" "$file"; then
    fail "docker must not receive $unexpected" "$(printf 'arguments were:\n'; cat "$file")"
  fi
}

run_make default
assert_arg "$work/docker-default.args" "OMARCHY_ARCH=x86_64"
assert_arg "$work/docker-default.args" "archlinux/archlinux:latest"
refute_arg "$work/docker-default.args" "--platform"
[[ -f $sandbox/release/omarchy-test-x86_64-quattro.iso ]] ||
  fail "default build names the x86_64 ISO" "$(ls "$sandbox/release")"
pass "default build is x86_64 in the Arch container with no platform override"
rm -f "$sandbox/release"/*.iso

run_make x86_64 --arch x86_64
assert_arg "$work/docker-x86_64.args" "OMARCHY_ARCH=x86_64"
assert_arg "$work/docker-x86_64.args" "archlinux/archlinux:latest"
refute_arg "$work/docker-x86_64.args" "--platform"
pass "--arch x86_64 matches the default"
rm -f "$sandbox/release"/*.iso

# Leave an x86_64 ISO behind: the aarch64 build must pick up its own output
# even when a newer-looking x86_64 file shares release/.
run_make aarch64 --arch=aarch64
assert_arg "$work/docker-aarch64.args" "OMARCHY_ARCH=aarch64"
assert_arg "$work/docker-aarch64.args" "--platform"
assert_arg "$work/docker-aarch64.args" "linux/arm64"
assert_arg "$work/docker-aarch64.args" "menci/archlinuxarm:latest"
refute_arg "$work/docker-aarch64.args" "archlinux/archlinux:latest"
[[ -f $sandbox/release/omarchy-test-aarch64-quattro.iso ]] ||
  fail "aarch64 build names the aarch64 ISO" "$(ls "$sandbox/release")"
pass "--arch aarch64 builds in an arm64 Arch Linux ARM container"

touch "$sandbox/release/omarchy-test-x86_64.iso"
run_make aarch64-shared --arch aarch64
[[ -f $sandbox/release/omarchy-test-x86_64.iso ]] ||
  fail "aarch64 build leaves the x86_64 output alone" "$(ls "$sandbox/release")"
pass "release/ is shared between architectures"

set +e
invalid_output=$(cd "$sandbox" && PATH="$work/stubs:$PATH" "$BASH" bin/omarchy-iso-make --arch sparc 2>&1)
invalid_status=$?
set -e
(( invalid_status != 0 )) || fail "unsupported architecture is rejected"
[[ $invalid_output == *"Unsupported architecture: sparc"* ]] ||
  fail "unsupported architecture names itself" "$invalid_output"
pass "--arch rejects anything but x86_64 and aarch64"
