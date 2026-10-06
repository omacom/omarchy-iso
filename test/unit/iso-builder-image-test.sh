#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/bin" "$work/repo/release" "$work/stubs" "$work/home"
cp "$ROOT/bin/omarchy-iso-make" "$work/repo/bin/"

cat >"$work/stubs/git" <<'STUB'
#!/bin/bash
if [[ $1 == "submodule" ]]; then
  printf '%s\n' "$*" >>"$TEST_GIT_LOG"
fi
STUB

cat >"$work/stubs/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_SUDO_LOG"
if [[ $1 == "docker" ]]; then
  shift
  exec docker "$@"
fi
STUB

cat >"$work/stubs/docker" <<'STUB'
#!/bin/bash
if [[ $1 == "version" ]]; then
  [[ ${TEST_DOCKER_NEEDS_SUDO:-0} == 0 ]]
elif [[ $1 == "run" ]]; then
  printf '%s\n' "$@" >>"$TEST_DOCKER_LOG"
  if [[ ${TEST_DOCKER_FAIL:-0} == 1 ]]; then
    exit 23
  fi
  printf 'fake iso\n' >"$TEST_RELEASE/omarchy.iso"
fi
STUB

chmod +x "$work/stubs"/*
export TEST_DOCKER_LOG="$work/docker.log" TEST_SUDO_LOG="$work/sudo.log"
export TEST_GIT_LOG="$work/git.log" TEST_RELEASE="$work/repo/release"
image="docker.io/archlinux/archlinux@sha256:a1cd6a460b8c8d2c9e9482d7853b7acab4888f448a7914fdc676ce037ff0a5dc"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

run_builder() {
  : >"$TEST_DOCKER_LOG"
  : >"$TEST_SUDO_LOG"
  : >"$TEST_GIT_LOG"
  rm -f "$TEST_RELEASE"/*.iso
  (cd "$work/repo" && PATH="$work/stubs:$PATH" HOME="$work/home" \
    "$work/repo/bin/omarchy-iso-make" --keep-pkg-cache --no-boot-offer "$@") >"$work/output" 2>&1
}

assert_pinned_run() {
  [[ $(head -n1 "$TEST_DOCKER_LOG") == "run" ]] || fail "docker run was not captured"
  [[ $(grep -cFx 'run' "$TEST_DOCKER_LOG") == 1 ]] || fail "builder launched another container"
  [[ $(grep -cFx "$image" "$TEST_DOCKER_LOG") == 1 ]] || fail "builder image is not the exact pin"
  [[ $(tail -n1 "$TEST_DOCKER_LOG") == "/builder/build-iso.sh" ]] || fail "builder command changed"
  grep -qxF -- '--privileged' "$TEST_DOCKER_LOG" || fail "privileged build flag changed"
  [[ $(cat "$TEST_GIT_LOG") == "submodule update --init --recursive --jobs=8" ]] || fail "submodule setup changed"
}

run_builder || fail "warm builder launch failed"
assert_pinned_run
if grep -qxF -- '--pull=always' "$TEST_DOCKER_LOG"; then fail "warm build pulled unconditionally"; fi
[[ -f $TEST_RELEASE/omarchy-quattro.iso ]] || fail "warm build did not finish"
printf 'ok - warm build uses pinned image\n'

run_builder --no-cache || fail "cold builder launch failed"
assert_pinned_run
grep -qxF -- '--pull=always' "$TEST_DOCKER_LOG" || fail "cold build lost pull behavior"
[[ -f $TEST_RELEASE/omarchy-quattro.iso ]] || fail "cold build did not finish"
printf 'ok - cold build refreshes pinned image\n'

TEST_DOCKER_NEEDS_SUDO=1 run_builder || fail "sudo builder launch failed"
assert_pinned_run
[[ $(cat "$TEST_SUDO_LOG") == docker\ run* ]] || fail "sudo docker fallback changed"
printf 'ok - socket denial uses sudo with pinned image\n'

if TEST_DOCKER_FAIL=1 run_builder; then fail "failed docker launch returned success"; fi
assert_pinned_run
[[ ! -e $TEST_RELEASE/omarchy-quattro.iso ]] || fail "failed launch produced an ISO"
printf 'ok - failed docker launch stops without image fallback\n'
