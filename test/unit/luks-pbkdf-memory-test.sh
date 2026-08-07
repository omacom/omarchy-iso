#!/bin/bash
#
# Drive omarchy-luks-pbkdf-memory against fake meminfo files. The helper must
# be invoked for every assertion; inlining the formula would let a stubbed
# helper (printf '65536\n') pass.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$ROOT/configs/airootfs/usr/local/bin/omarchy-luks-pbkdf-memory"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"
  printf 'not ok - %s\n' "$description" >&2
  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  exit 1
}

[[ -x $helper ]] || fail "helper is executable" "missing $helper"

fake_meminfo=$(mktemp)
trap 'rm -f "$fake_meminfo"' EXIT

run_helper() {
  OMARCHY_LUKS_MEMINFO="$fake_meminfo" "$helper"
}

# 4 GiB available: 2x the 256 MiB default fits.
printf 'MemAvailable:    4194304 kB\n' >"$fake_meminfo"
out=$(run_helper) || fail "default on plenty of RAM" "helper exited $?"
[[ $out == 262144 ]] || fail "default on plenty of RAM" "expected 262144, got $out"
pass "default 256 MiB when MemAvailable is 4 GiB"

# 512 MiB available: 256 MiB default needs 512 MiB free (2x), so this is the
# exact threshold for the default.
printf 'MemAvailable:    524288 kB\n' >"$fake_meminfo"
out=$(run_helper) || fail "default at 2x threshold" "helper exited $?"
[[ $out == 262144 ]] || fail "default at 2x threshold" "expected 262144, got $out"
pass "default 256 MiB when MemAvailable is exactly 2x 256 MiB"

# Just under 2x default (511 MiB): cannot fit 256 MiB, can fit 64 MiB floor.
printf 'MemAvailable:    523264 kB\n' >"$fake_meminfo"
out=$(run_helper 2>/dev/null) || fail "floor when default cannot fit" "helper exited $?"
[[ $out == 65536 ]] || fail "floor when default cannot fit" "expected 65536, got $out"
pass "64 MiB floor when MemAvailable cannot fit 256 MiB"

# 128 MiB available: exact 2x floor threshold.
printf 'MemAvailable:    131072 kB\n' >"$fake_meminfo"
out=$(run_helper 2>/dev/null) || fail "floor at 2x threshold" "helper exited $?"
[[ $out == 65536 ]] || fail "floor at 2x threshold" "expected 65536, got $out"
pass "64 MiB floor when MemAvailable is exactly 2x 64 MiB"

# 64 MiB available: floor itself cannot fit (would consume all free RAM).
printf 'MemAvailable:    65536 kB\n' >"$fake_meminfo"
if out=$(run_helper 2>/dev/null); then
  fail "refuse when floor cannot fit" "helper printed $out instead of failing"
fi
pass "refuses to format when MemAvailable cannot fit the 64 MiB floor"

# Unreadable / missing MemAvailable: treat as 0 and refuse.
printf 'MemTotal:    16777216 kB\n' >"$fake_meminfo"
if out=$(run_helper 2>/dev/null); then
  fail "refuse without MemAvailable" "helper printed $out instead of failing"
fi
pass "refuses to format when meminfo has no MemAvailable"

echo "luks-pbkdf-memory-test: ok"
