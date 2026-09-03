#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT

mkdir -p "$BOX/omarchy"
printf 'OMARCHY\n' >"$BOX/omarchy/logo.txt"
: >"$BOX/install.log"
awk '/^\[\[ -e \$TTY_PATH \]\] \|\| exit 2$/ { exit } { print }' "$DASHBOARD" >"$BOX/dashboard-defs.sh"

duration_for() {
  printf '%s\n' "$1" >"$BOX/state.json"
  (
    OMARCHY_DASHBOARD_TTY=/dev/null OMARCHY_PATH="$BOX/omarchy" \
      source "$BOX/dashboard-defs.sh" "$BOX/install.log" "$BOX/state.json" -- true
    install_duration
  )
}

got=$(duration_for '{"duration_seconds": 29.6, "started_at": 1000, "finished_at": 900}')
if [[ $got != "0m 30s" ]]; then
  echo "FAIL: monotonic duration should win over a backwards wall clock (got '$got')" >&2
  exit 1
fi
echo "ok: monotonic duration wins over a backwards wall clock"

got=$(duration_for '{"started_at": 1000, "finished_at": 1062}')
if [[ $got != "1m 2s" ]]; then
  echo "FAIL: legacy wall-clock duration should remain supported (got '$got')" >&2
  exit 1
fi
echo "ok: legacy wall-clock duration remains supported"
