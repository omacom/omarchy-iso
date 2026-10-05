#!/bin/bash
#
# Unit tests for omarchy-install-dashboard's try mode: with OMARCHY_DASHBOARD_TRY
# it must return the child's status and never show the install's failure menu
# or reboot prompt, since Try Omarchy's session — not a reboot — comes next.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASH="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

pass() { printf 'ok - %s\n' "$1"; }
fail() { local d="$1" x="${2:-}"; [[ -n $x ]] && printf '%s\n' "$x" >&2; printf 'not ok - %s\n' "$d" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/omarchy"; printf 'OMARCHY\n' >"$work/omarchy/logo.txt"
printf '0\n' >"$work/expected-packages"

run_dash() { # <child-status>
  local tty=$work/tty.$1; : >"$tty"
  OMARCHY_DASHBOARD_TRY=yes OMARCHY_DASHBOARD_TTY="$tty" OMARCHY_PATH="$work/omarchy" \
    OMARCHY_EXPECTED_PACKAGES_FILE="$work/expected-packages" OMARCHY_UI_INTERACTIVE=no \
    timeout 60 "$DASH" "$work/install.$1.log" "$work/state.$1.json" -- bash -c "exit $1"
}

status=0; run_dash 0 >/dev/null 2>&1 || status=$?
(( status == 0 )) || fail "try mode returns the child's success" "status=$status"
! grep -qiE 'reboot|celebrat|Return to' "$work/tty.0" || fail "try mode shows no reboot prompt on success" "$(<"$work/tty.0")"
pass "dashboard try mode exits 0 with the child and shows no reboot prompt"

status=0; run_dash 3 >/dev/null 2>&1 || status=$?
(( status == 3 )) || fail "try mode returns the child's failure status" "status=$status"
! grep -qiE 'stopped|Discord|upload' "$work/tty.3" || fail "try mode shows no failure menu" "$(<"$work/tty.3")"
pass "dashboard try mode exits with the child's status and shows no failure menu"
