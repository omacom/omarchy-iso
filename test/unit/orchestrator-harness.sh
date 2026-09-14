# shellcheck shell=bash
# Shared harness for the orchestrator unit tests. Sourced, not executed.
#
# The orchestrator's modules are sourced into the test shell; phases run in a
# subshell with the same errexit/trap setup main.sh uses, against a temp
# target, with the commands that would touch the system (arch-chroot, mount,
# findmnt, …) shadowed by recording functions defined per test.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ORCHESTRATOR="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator"
for _m in ui context phases archinstall root_image install limine target_setup provisioning lifecycle; do
  # shellcheck disable=SC1090
  source "$ORCHESTRATOR/$_m.sh"
done
unset _m

# The system-touching commands each test shadows are its own business, but
# systemd must be shadowed for every test unconditionally: the orchestrator's
# exit paths run `systemctl stop` on install-medium units, and on a
# developer's host that is not a no-op -- a non-root systemctl raises a
# polkit password prompt on the desktop for a unit that does not even exist
# there, swallowed by the callers' `|| true` so the suite stays green while
# it rings. Tests that need behavior redefine these per test as usual.
systemctl() { :; }
journalctl() { :; }
systemd-escape() { command systemd-escape "$@"; }

failures=0
section() { printf '==> %s\n' "$*"; }
# The assertion runs as a plain statement, not as an `if` condition: a
# subshell started from a context where errexit is ignored (if conditions,
# `!`, && / || lists) ignores its own `set -e` too, which would hide phase
# failures that only errexit catches.
check() {
  local label=$1 rc
  shift
  "$@"
  rc=$?
  if ((rc == 0)); then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s\n' "$label"
    failures=$((failures + 1))
  fi
}
eq() { [[ $1 == "$2" ]] || { printf '       expected %q, got %q\n' "$2" "$1"; return 1; }; }
contains() { [[ $1 == *"$2"* ]] || { printf '       %q does not contain %q\n' "$1" "$2"; return 1; }; }
mode_of() { stat -c %a "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CALLS="$TMP/calls"
ERR="$TMP/stderr"
record() { printf '%s\n' "$*" >>"$CALLS"; }
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : >"$CALLS"; }

# Quiet progress lines in tests.
info() { :; }

# run_phase FN [args]: errexit + ERR trap as in main.sh, stderr captured in
# $ERR, status returned.
run_phase() {
  ( set -eE; trap 'true' ERR; "$@" ) 2>"$ERR"
}

# Temp target + context defaults for a phase test (make_ctx in Python).
fresh_target() {
  rm -rf "${TMP:?}/mnt" "${TMP:?}/state"
  mkdir -p "$TMP/mnt" "$TMP/state"
  CTX_TARGET="$TMP/mnt"
  CTX_STATE_DIR="$TMP/state"
  CTX_DEFER_PROVISIONING=true
  CTX_ENCRYPT=false
  CTX_USERNAME=''
  CTX_OMARCHY_INSTALL='{"mode": "full_disk", "defer_provisioning": true, "storage": {}}'
  CTX_USER_CONFIGURATION='{"disk_config": {}}'
  CTX_USER_CREDENTIALS='{"users": []}'
  CTX_AUTHORIZED_KEYS_PATH=''
  CTX_TAILSCALE_AUTHKEY_PATH=''
  CTX_IS_PROTECTED=false
  reset_calls
}

finish() {
  if ((failures)); then
    printf '\n%d check(s) failed\n' "$failures"
    exit 1
  fi
  printf '\nall checks passed\n'
}
