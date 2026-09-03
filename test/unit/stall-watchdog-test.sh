#!/bin/bash
#
# Unit tests for omarchy-stall-watchdog. The wrapper's contract: a child
# whose process tree keeps reading is left alone and its exit status comes
# back verbatim; a tree that stops reading for OMARCHY_STALL_SECS is killed
# and the wrapper exits 75 (what omarchy-wait-verify names a stalled
# medium). The cases run the real wrapper around real children with the
# knobs turned down so the whole file runs in seconds.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WATCHDOG="$ROOT/configs/airootfs/usr/local/bin/omarchy-stall-watchdog"

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

dd if=/dev/zero of="$work/payload" bs=1024 count=64 status=none

run_watchdog() { # stall_secs, sample_secs, command...
  local stall=$1 sample=$2
  shift 2
  set +e
  OMARCHY_STALL_SECS="$stall" OMARCHY_STALL_SAMPLE_SECS="$sample" \
    "$WATCHDOG" "$@" 2>"$work/stderr"
  RC=$?
  set -e
}

# --- a reader that finishes is passed through untouched -----------------

run_watchdog 2 1 bash -c 'cat "$1" >/dev/null' _ "$work/payload"
[[ $RC == 0 ]] || fail "completing reader" "rc=$RC $(cat "$work/stderr")"
pass "a completing reader exits 0 through the wrapper"

# --- a child's own failure comes back verbatim --------------------------

run_watchdog 5 1 bash -c 'cat "$1" >/dev/null; exit 3' _ "$work/payload"
[[ $RC == 3 ]] || fail "exit status propagation" "rc=$RC"
pass "a failing child's exit status is propagated verbatim"

# --- a stalled tree is killed and named as a stall ----------------------

start=$SECONDS
run_watchdog 2 1 bash -c 'exec sleep 60'
took=$((SECONDS - start))
[[ $RC == 75 ]] || fail "stall detection" "rc=$RC $(cat "$work/stderr")"
((took < 15)) || fail "stall verdict speed" "took ${took}s"
grep -q "no read progress" "$work/stderr" ||
  fail "stall names itself" "$(cat "$work/stderr")"
pass "a stalled tree is killed within seconds and exits 75"

# --- a trickling reader outlives the stall threshold --------------------

# Reads one block every ~0.4s for ~4s: far slower than any timeout floor,
# but alive -- exactly the case the watchdog must NOT kill (the size-based
# TimeoutStartSec owns slow-but-alive).
run_watchdog 2 1 bash -c '
  for i in $(seq 1 10); do
    head -c 1024 "$1" >/dev/null
    sleep 0.4
  done' _ "$work/payload"
[[ $RC == 0 ]] || fail "trickling reader survives" "rc=$RC $(cat "$work/stderr")"
pass "a trickling reader outlives the stall threshold and completes"

# --- reads by a grandchild count as progress ----------------------------

# The mirror verifier forks per-file hashers: the parent sits in a loop
# while its children do the reading. Progress anywhere in the tree is life.
run_watchdog 2 1 bash -c '
  bash -c "for i in \$(seq 1 10); do head -c 1024 \"$1\" >/dev/null; sleep 0.4; done" &
  wait' _ "$work/payload"
[[ $RC == 0 ]] || fail "grandchild progress counts" "rc=$RC $(cat "$work/stderr")"
pass "reads by a grandchild count as progress"

echo "all stall-watchdog tests passed"
