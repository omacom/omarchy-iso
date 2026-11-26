#!/bin/bash
#
# The x86_64 ISO must fit an 8 GB stick (builder/build-iso.sh check_iso_size):
# over 7.7 GB fails the build and over 7.5 GB warns, at the compression the
# ISO ships with. A fast build compresses the root image less, so it only
# reports its size. Sparse files stand in for the ISOs.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$(sed -n '/^check_iso_size() {$/,/^}$/p' "$ROOT/builder/build-iso.sh")"
declare -F check_iso_size >/dev/null || fail "build-iso.sh has no check_iso_size"
# shellcheck disable=SC2016 # the call as written in build-iso.sh, unexpanded
grep -Fqx '  check_iso_size "$iso" || exit 1' "$ROOT/builder/build-iso.sh" ||
  fail "build-iso.sh does not fail the build when check_iso_size does"

iso() {
  truncate -s "$1" "$work/omarchy.iso"
  echo "$work/omarchy.iso"
}

# The ISO that failed pull-request CI at 4d3d128, and the same commit as shipped.
fast=7758364672
shipped=7026540544

export OMARCHY_ARCH=x86_64
unset OMARCHY_FAST_COMPRESSION
if check_iso_size "$(iso $fast)" >/dev/null 2>"$work/err"; then fail "an ISO over 7.7 GB passed"; fi
grep -q "over the 7700000000 limit for an 8 GB stick" "$work/err" || fail "the failure does not say why: $(cat "$work/err")"
echo "ok - an ISO over 7.7 GB at the shipped compression fails the build"

check_iso_size "$(iso 7600000000)" >/dev/null 2>"$work/err" || fail "an ISO between 7.5 and 7.7 GB failed"
grep -q "^WARNING: " "$work/err" || fail "an ISO between 7.5 and 7.7 GB did not warn"
echo "ok - an ISO between 7.5 and 7.7 GB warns"

check_iso_size "$(iso $shipped)" >/dev/null 2>"$work/err" || fail "an ISO under 7.5 GB failed"
[[ ! -s $work/err ]] || fail "an ISO under 7.5 GB warned: $(cat "$work/err")"
echo "ok - an ISO under 7.5 GB passes quietly"

export OMARCHY_FAST_COMPRESSION=1
out=$(check_iso_size "$(iso $fast)" 2>"$work/err") || fail "a fast build over 7.7 GB failed"
[[ ! -s $work/err ]] || fail "a fast build warned: $(cat "$work/err")"
[[ $out == *"$fast bytes"* && $out == *"fast build"* ]] || fail "a fast build does not report its size and why it is not held: $out"
echo "ok - a fast build reports its size and leaves the limit to shipped builds"

export OMARCHY_ARCH=aarch64
unset OMARCHY_FAST_COMPRESSION
check_iso_size "$(iso $fast)" >/dev/null 2>&1 || fail "an aarch64 ISO over 7.7 GB failed"
echo "ok - aarch64 ISOs are not held to an 8 GB stick"
