#!/bin/bash
#
# Unit tests for the finish screen's duration. Explicit units at every scale,
# thousandths only below a minute, and whole seconds for old wall-clock states.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

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

# The dashboard is a program, not a library: lift the function under test out
# of it rather than running the whole screen.
eval "$(sed -n '/^install_duration() {/,/^}/p' "$DASHBOARD")"
# install_duration falls through to the log files when the state has no time.
# shellcheck disable=SC2034
LOG_FILE="$work/absent.log"

duration_for() {
  local state="$work/state.json"
  printf '%s\n' "$1" >"$state"
  STATE_FILE="$state" install_duration
}

expect() {
  local description="$1" state="$2" want="$3" got
  got="$(duration_for "$state")"
  [[ $got == "$want" ]] || fail "$description" "want '$want', got '$got'"
  pass "$description"
}

expect "under a minute shows explicit units and thousandths" \
  '{"total_elapsed_ns": 45889123456}' \
  "0 min 45.889 s"

expect "the last thousandth under a minute still shows" \
  '{"total_elapsed_ns": 59999999999}' \
  "0 min 59.999 s"

expect "a minute exactly drops the thousandths" \
  '{"total_elapsed_ns": 60000000000}' \
  "1 min 0 s"

expect "over a minute truncates to whole seconds" \
  '{"total_elapsed_ns": 100557000000}' \
  "1 min 40 s"

expect "a slow install shows whole seconds" \
  '{"total_elapsed_ns": 414700000000}' \
  "6 min 54 s"

expect "under an hour has no hour digit" \
  '{"total_elapsed_ns": 3599999000000}' \
  "59 min 59 s"

expect "an hour exactly adds the hour unit" \
  '{"total_elapsed_ns": 3600000000000}' \
  "1 h 0 min 0 s"

expect "over an hour uses explicit units and whole seconds" \
  '{"total_elapsed_ns": 10823555000000}' \
  "3 h 0 min 23 s"

expect "a legacy state uses explicit units without invented precision" \
  '{"started_at": 1000.0, "finished_at": 1100.6}' \
  "1 min 41 s"

expect "subsecond installs pad the thousandths" \
  '{"total_elapsed_ns": 5000000}' \
  "0 min 0.005 s"

expect "just over a minute does not show thousandths" \
  '{"total_elapsed_ns": 60001000000}' \
  "1 min 0 s"

expect "legacy hour duration uses explicit units" \
  '{"started_at": 1000.0, "finished_at": 4723.0}' \
  "1 h 2 min 3 s"
