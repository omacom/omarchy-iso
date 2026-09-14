#!/usr/bin/env bash
# The systemd-backed phase state: progress published over sd_notify, the
# timing record generated from systemd's own unit timestamps, and the exit
# trap's cleanup. The unit graph itself is the install's state now -- there
# is no parallel document to seed, enter or finalize per phase.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

cleanup_target_hook_masks() { record cleanup_target_hook_masks; }
cleanup_protected_state() { record cleanup_protected_state; }
systemctl() { record "systemctl $*"; }
error() { printf '%s\n' "$*" >&2; }

section 'progress rides sd_notify STATUS='
systemd-notify() { record "systemd-notify $* socket=${NOTIFY_SOCKET:-}"; }
reset_calls
# Unset in a subshell: a desktop session exports its own NOTIFY_SOCKET, and
# in production the unit's own socket must win when present.
(unset NOTIFY_SOCKET; phases_write_progress 0.25)
check 'fraction published' contains "$(calls)" '--status=progress=0.25'
check 'socket defaulted for watcher subshells' contains "$(calls)" 'socket=/run/systemd/notify'
reset_calls
(NOTIFY_SOCKET=/run/unit/socket phases_write_progress 0.25)
check 'the unit-provided socket wins' contains "$(calls)" 'socket=/run/unit/socket'
reset_calls
phases_write_progress bogus
phases_write_progress ''
check 'garbage never reaches systemd' eq "$(calls)" ''
# Progress is best effort: a notify failure must never fail the phase.
systemd-notify() { return 1; }
check 'a failed notify is swallowed' phases_write_progress 0.5
unset -f systemd-notify

section 'the timing record comes from the unit timestamps'
fresh_target
UNITS="$TMP/units"
rm -rf "$UNITS"
mkdir -p "$UNITS"
export OMARCHY_INSTALL_UNITS_DIR="$UNITS"
make_unit() { # unit-basename display-name
  printf '[Service]\nExecStart=/usr/share/omarchy-iso/orchestrator/run-phase fn "%s"\n' \
    "$2" >"$UNITS/omarchy-install-$1.service"
}
make_unit alpha 'First phase'
make_unit beta 'Second phase'
make_unit gamma 'Never ran'
# Not a phase unit: no run-phase ExecStart, must not appear in the record.
printf '[Service]\nExecStart=/usr/bin/true\n' >"$UNITS/omarchy-install-helper.service"
# The stub answers `show <unit> -p ActiveState,Result,ExecMainStart...,ExecMainExit... --value`
# in systemctl's --value format: one line per property, in the asked order.
# beta started first and failed; alpha ran after it and succeeded (the sort
# must follow the timestamps, not the file names); gamma never ran.
systemctl() {
  case "$2" in
    omarchy-install-alpha.service) printf 'active\nsuccess\n2000000\n3500000\n' ;;
    omarchy-install-beta.service) printf 'failed\nexit-code\n1000000\n1750000\n' ;;
    omarchy-install-gamma.service) printf 'inactive\nsuccess\n0\n0\n' ;;
    *) printf 'inactive\nsuccess\n0\n0\n' ;;
  esac
}
mkdir -p "$CTX_TARGET/var/lib/pacman/local/pkg-one-1.0-1" "$CTX_TARGET/var/lib/pacman/local/pkg-two-1.0-1"
expected_package_count() { printf 3; }
phases_finalize
TIMING="$CTX_TARGET/var/log/omarchy-install-timing.json"
check 'timing copy in target' test -f "$TIMING"
check 'phases in start order, only the ones that ran' \
  eq "$(jq -r '[.phases[].name] | join(",")' "$TIMING")" 'Second phase,First phase'
check 'status from the unit result' \
  eq "$(jq -r '[.phases[].status] | join(",")' "$TIMING")" 'failed,ok'
check 'elapsed from the monotonic pair' \
  eq "$(jq -r '[.phases[].elapsed] | join(",")' "$TIMING")" '0.750,1.500'
check 'package counts recorded' \
  eq "$(jq -r '"\(.installed_packages)/\(.expected_packages)"' "$TIMING")" '2/3'
check 'finished stamp present' test "$(jq -r .finished_at "$TIMING")" != null
unset OMARCHY_INSTALL_UNITS_DIR
systemctl() { record "systemctl $*"; }

section 'the journal export lands beside the session log'
# The stub answers both queries the export makes: the unit glob -- wide
# enough for the verifies and the other supporting units, not only the
# phases -- with a phase's own line (plus an escape sequence the filter must
# strip) and a verify unit's, and the identifier query with the milestones.
journalctl() {
  if [[ $* == *"-u *omarchy*"* ]]; then
    printf '2026-09-01T09:35:30+00:00 archiso omarchy-verify-mirror[80]: mirror checksum verified\n'
    [[ $* == *"-u *.mount"* ]] && printf '2026-09-01T09:35:40+00:00 archiso systemd[1]: Mounted /mnt/opt/packages.\n'
    printf '2026-09-01T09:36:00+00:00 archiso run-phase[99]: \033[1mpacstrap\033[0m: package foo is corrupted\n'
  else
    printf '2026-09-01T09:35:00+00:00 archiso omarchy-install-milestone[1]: -----BEGIN OMARCHY INSTALL-----\n'
  fi
}
ORCHESTRATOR_DIR="$ORCHESTRATOR"
export_install_journal "$TMP/exported.log"
EXPORTED=$(cat "$TMP/exported.log")
check 'section header' contains "$EXPORTED" '=== install journal (*omarchy* and *.mount units) ==='
check 'the phase output, escapes filtered' contains "$EXPORTED" 'run-phase[99]: pacstrap: package foo is corrupted'
check 'the supporting units are in it too' contains "$EXPORTED" 'omarchy-verify-mirror[80]: mirror checksum verified'
check 'and the mount units' contains "$EXPORTED" 'systemd[1]: Mounted /mnt/opt/packages.'
check 'the milestones follow' contains "$EXPORTED" '-----BEGIN OMARCHY INSTALL-----'
check 'the finalize appended it to the target log' \
  contains "$(cat "$CTX_TARGET/var/log/omarchy-install.log")" '=== install journal (*omarchy* and *.mount units) ==='

section 'exit trap: cleanup on the failure path'
fresh_target
reset_calls
CTX_LOG_PATH="$TMP/live-session.log"
printf '[orchestrator] Installing Omarchy\n' >"$CTX_LOG_PATH"
(
  set -eEuo pipefail
  trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap orchestrator_on_exit EXIT
  fail 'graph start failed'
) 2>"$ERR"
check 'exit 1' eq "$?" 1
check 'halt message' contains "$(cat "$ERR")" 'Installation halted.'
check 'group abort issued' contains "$(calls)" 'systemctl stop omarchy-install.target'
check 'the protected-target release ran' contains "$(calls)" cleanup_protected_state
check 'the failing phases'\'' journal is appended to the session log' \
  contains "$(cat "$CTX_LOG_PATH")" 'package foo is corrupted'
check 'the session log keeps its spine first' \
  test "$(head -n1 "$CTX_LOG_PATH")" == '[orchestrator] Installing Omarchy'
journalctl() { :; }
unset CTX_LOG_PATH
check 'the target hook unmask is the system unit'\''s, not the trap'\''s' \
  test -z "$(calls | grep cleanup_target_hook_masks || true)"

section 'exit trap: an interrupt tells its own story'
fresh_target
reset_calls
(
  set -eEuo pipefail
  trap orchestrator_on_exit EXIT
  ORCH_INTERRUPTED=true
  exit 130
) 2>"$ERR"
check 'exit 130' eq "$?" 130
check 'interrupt message' contains "$(cat "$ERR")" 'Installation interrupted.'
check 'group abort issued' contains "$(calls)" 'systemctl stop omarchy-install.target'

finish
