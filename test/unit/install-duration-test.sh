#!/bin/bash
#
# Unit tests for the finish screen's lap time. The dashboard reads the run
# time the orchestrator publishes in nanoseconds, shows it as m:ss.mmm on
# both sides of the minute, and falls back to the old wall-clock m/s form for
# state files that predate it.

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

# The dashboard is a program, not a library: lift the two functions under test
# out of it rather than running the whole screen.
eval "$(sed -n '/^install_duration() {/,/^}/p; /^run_code() {/,/^}/p' "$DASHBOARD")"
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

expect "under a minute keeps the minute digit" \
  '{"total_elapsed_ns": 45889123456, "run_id": "86c897ee-0000-4000-8000-000000000000"}' \
  "0:45.889"

expect "the last thousandth under a minute still shows" \
  '{"total_elapsed_ns": 59999999999}' \
  "0:59.999"

expect "a minute exactly keeps the thousandths" \
  '{"total_elapsed_ns": 60000000000}' \
  "1:00.000"

expect "over a minute is the same shape" \
  '{"total_elapsed_ns": 100557000000}' \
  "1:40.557"

expect "a slow install pads its seconds" \
  '{"total_elapsed_ns": 414700000000}' \
  "6:54.700"

expect "under an hour has no hour digit" \
  '{"total_elapsed_ns": 3599999000000}' \
  "59:59.999"

expect "an hour exactly switches to endurance form" \
  '{"total_elapsed_ns": 3600000000000}' \
  "1:00:00.000"

expect "over an hour is h:mm:ss.mmm" \
  '{"total_elapsed_ns": 10823555000000}' \
  "3:00:23.555"

expect "a state file without the phase sum keeps the m/s form" \
  '{"started_at": 1000.0, "finished_at": 1100.6}' \
  "1m 41s"

state="$work/state.json"
printf '%s\n' '{"total_elapsed_ns": 45889123456, "run_id": "86c897ee-0000-4000-8000-000000000000"}' >"$state"
code="$(STATE_FILE="$state" run_code)"
[[ $code == "86c897ee" ]] || fail "run code is the first eight characters of the run id" "got '$code'"
pass "run code is the first eight characters of the run id"

printf '%s\n' '{"total_elapsed_ns": 100557000000, "run_id": "bf95d41d-0000-4000-8000-000000000000"}' >"$state"
code="$(STATE_FILE="$state" run_code)"
[[ $code == "bf95d41d" ]] || fail "run code stays over a minute" "got '$code'"
pass "run code stays over a minute"
