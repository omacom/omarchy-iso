#!/bin/bash
#
# The behavior of the install's systemd hosting, driven for real: the
# run-phase entrypoint (dispatch, the destruction boundary, the failure-path
# mount cleanup and error handover), the orchestrator's unit join, the CPU
# governor helper against a fake sysfs, and the cross-process passphrase
# guarantee. What a unit file merely declares is not restated here — the
# integration installs prove the wiring.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ORCH="$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator"

failures=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    failures=$((failures + 1))
  fi
}

# The governor helper: boost and restore run in different processes, so the
# mechanics are driven against a fake sysfs to prove the state file carries
# the governors across.
cpu_governor_mechanics() {
  local d
  d=$(mktemp -d) || return 1
  mkdir -p "$d/sys/cpu0/cpufreq" "$d/sys/cpu1/cpufreq"
  printf 'schedutil\n' >"$d/sys/cpu0/cpufreq/scaling_governor"
  printf 'powersave\n' >"$d/sys/cpu1/cpufreq/scaling_governor"
  CPU_SYSFS="$d/sys" OMARCHY_INSTALL_STATE_DIR="$d/state" \
    "$ROOT/configs/airootfs/usr/local/bin/omarchy-cpu-governor" boost >/dev/null &&
  [[ $(<"$d/sys/cpu0/cpufreq/scaling_governor") == performance ]] &&
  [[ $(<"$d/sys/cpu1/cpufreq/scaling_governor") == performance ]] &&
  CPU_SYSFS="$d/sys" OMARCHY_INSTALL_STATE_DIR="$d/state" \
    "$ROOT/configs/airootfs/usr/local/bin/omarchy-cpu-governor" restore &&
  [[ $(<"$d/sys/cpu0/cpufreq/scaling_governor") == schedutil ]] &&
  [[ $(<"$d/sys/cpu1/cpufreq/scaling_governor") == powersave ]] &&
  [[ ! -e $d/state/cpu-governors ]]
  local rc=$?
  rm -rf "$d"
  return $rc
}
check "boost and restore carry the governors through the state file" cpu_governor_mechanics

# run-phase itself: sourceable main.sh, dispatch, refusals — including the
# destruction boundary, which must fail loudly rather than skip.
check "sourcing main.sh defines but does not run the install" \
  bash -c "env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' bash -c \
    \"source '$ORCH/main.sh' && declare -F main >/dev/null && declare -F install_root_image >/dev/null\""
check "run-phase refuses an unknown phase" \
  bash -c "! env OMARCHY_ARCHINSTALL_LIB='$ROOT/archinstall-bash/lib' '$ORCH/run-phase' no_such_phase 2>/dev/null"

fixtures=$(mktemp -d)
trap 'rm -rf "$fixtures"' EXIT
cat >"$fixtures/config.json" <<'JSON'
{"disk_config": {"config_type": "default_layout", "device_modifications": []},
 "bootloader_config": {"bootloader": "limine"}, "hostname": "phase-smoke",
 "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"}}
JSON
printf '{"users": [{"username": "smoke", "!password": "x"}]}\n' >"$fixtures/creds.json"
run_phase_env() { # extra-env... phase
  env OMARCHY_INSTALL_CONFIG="$fixtures/config.json" OMARCHY_INSTALL_CREDS="$fixtures/creds.json" \
    OMARCHY_INSTALL_STATE_DIR="$fixtures/state" OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" \
    "$@"
}
check "run-phase rebuilds context and library config, then dispatches" \
  bash -c "$(declare -f run_phase_env); fixtures='$fixtures'; ROOT='$ROOT'
    run_phase_env env RUN_PHASE_NO_TARGET=1 '$ORCH/run-phase' config_summary 2>/dev/null | grep -q phase-smoke"
check "and persisted the env files a phase unit would read" \
  bash -c "test -f '$fixtures/state/context.env' && test -f '$fixtures/state/install.env'"
check "run-phase refuses a phase before the disk phase mounted the target" \
  bash -c "$(declare -f run_phase_env); fixtures='$fixtures'; ROOT='$ROOT'
    run_phase_env '$ORCH/run-phase' config_summary 2>&1 | grep -q 'not a mounted install target'"

# run-phase's exit trap owns only the error handover (stage mounts are
# systemd mounts torn down by PartOf= when the target stops): a clean exit
# must hand nothing over, or a stale message from an earlier attempt would
# headline a phase that succeeded.
cleanup_trap_mechanics() {
  local d
  d=$(mktemp -d) || return 1
  sed -n '/^run_phase_cleanup() {/,/^}/p' "$ORCH/run-phase" >"$d/fn.sh"
  bash -c '
    systemd-cat() { cat >>"'"$d"'/handover"; }
    source "'"$d"'/fn.sh"
    CTX_STATE_DIR="'"$d"'"
    ORCH_LAST_ERROR="should never be written"
    (exit 0); run_phase_cleanup
  '
  local rc=0
  [[ -s $d/handover ]] && rc=1
  rm -rf "$d"
  return "$rc"
}
check "run-phase hands nothing over on a clean exit" cleanup_trap_mechanics

# And hands the phase's own fail() message to the journal under its own
# identifier — the plain unit stream buries it under command output and
# systemd's exit lines, which is exactly how the re-flash advice got lost
# once.
error_handover() {
  local d got
  d=$(mktemp -d) || return 1
  sed -n '/^run_phase_cleanup() {/,/^}/p' "$ORCH/run-phase" >"$d/fn.sh"
  bash -c '
    systemd-cat() { printf "systemd-cat %s <- " "$*" >>"'"$d"'/handover"; cat >>"'"$d"'/handover"; }
    source "'"$d"'/fn.sh"
    CTX_STATE_DIR="'"$d"'"
    RUN_PHASE_UNIT=omarchy-install-doomed.service
    ORCH_LAST_ERROR="install medium is corrupt: re-flash it"
    (exit 1); run_phase_cleanup
  '
  got=$(cat "$d/handover" 2>/dev/null)
  rm -rf "$d"
  [[ $got == "systemd-cat -t omarchy-phase-error -p err <- omarchy-install-doomed.service: install medium is corrupt: re-flash it" ]]
}
check "run-phase hands the phase's fail message over on a failing exit" error_handover

graph_failure_prefers_handover() {
  local d out fallback
  d=$(mktemp -d) || return 1
  # set -eE plus an ERR trap is main()'s regime: a missing handover file
  # once turned the detail collector itself into the reported failure.
  # The handover is a journal entry under its own identifier, each line
  # prefixed with the failing unit's name; the fallback case has no such
  # entry, only the buried noise of the plain unit stream.
  out=$(bash -c '
    set -eEuo pipefail; trap "echo ERR-TRAP-FIRED; exit 1" ERR
    journalctl() {
      [[ $* == *"-t omarchy-phase-error"* ]] &&
        { echo "some.unit: install medium is too slow: try another USB stick"; return 0; }
      echo "systemd noise only"
    }
    '"$(sed -n '/^phase_graph_failure_detail() {/,/^}/p' "$ORCH/main.sh")"'
    phase_graph_failure_detail some.unit
  ' 2>&1)
  fallback=$(bash -c '
    set -eEuo pipefail; trap "echo ERR-TRAP-FIRED; exit 1" ERR
    journalctl() {
      [[ $* == *"-t omarchy-phase-error"* ]] && return 0
      echo "systemd noise only"
    }
    '"$(sed -n '/^phase_graph_failure_detail() {/,/^}/p' "$ORCH/main.sh")"'
    phase_graph_failure_detail some.unit
  ' 2>&1)
  rm -rf "$d"
  [[ $out == *"install medium is too slow"* && $out != *"systemd noise"* &&
     $fallback == *"systemd noise only"* && $fallback != *ERR-TRAP-FIRED* ]]
}
check "the graph failure headline prefers the handed-over message to the journal" graph_failure_prefers_handover

# The target-setup clock is the anchor unit's systemd timestamp: the system
# and user phases run in different processes (concurrently, once the graph
# fans out) and must agree on the start time without passing state, and the
# log header belongs to the anchor phase alone, written once.
finalizer_clock_from_the_anchor_unit() {
  local d expect rc=0
  d=$(mktemp -d) || return 1
  expect=$(date -d "Sun 2026-08-31 07:41:02 UTC" +%s)
  run_finalizer_probe() { # unit-name label
    bash -c '
      systemctl() { echo "Sun 2026-08-31 07:41:02 UTC"; }
      CTX_LOG_PATH="'"$d"'/log"
      CTX_OMARCHY_START_TIME= CTX_OMARCHY_START_EPOCH= CTX_FINALIZER_HEADER_WRITTEN=false
      '"$(sed -n '/^OMARCHY_SETUP_ANCHOR_UNIT=/,/^}/p' "$ORCH/target_setup.sh")"'
      RUN_PHASE_UNIT='"$1"'
      ensure_finalizer_log_started
      ensure_finalizer_log_started
      echo "'"$2"'=$CTX_OMARCHY_START_EPOCH" >>"'"$d"'/out"
    '
  }
  run_finalizer_probe omarchy-install-system.service anchor_epoch
  run_finalizer_probe omarchy-install-user.service user_epoch
  grep -q "anchor_epoch=$expect" "$d/out" || rc=1
  grep -q "user_epoch=$expect" "$d/out" || rc=1
  [[ $(grep -c 'Omarchy Target Setup Started' "$d/log") == 1 ]] || rc=1
  rm -rf "$d"
  return "$rc"
}
check "system and user phases agree on the anchor unit's start time; one header" \
  finalizer_clock_from_the_anchor_unit

# Every chroot must run in a private mount namespace (concurrent chroots on
# one target unmount each other's API filesystems), and the escape hatch
# must reach the real binary. Driven with a recording unshare and a PATH
# stub standing in for arch-chroot itself.
chroot_namespace_wrapper() {
  local d out rc=0
  d=$(mktemp -d) || return 1
  printf '#!/bin/bash\necho "real $*" >>"%s/calls"\n' "$d" >"$d/arch-chroot"
  chmod +x "$d/arch-chroot"
  out=$(bash -c '
    unshare() { echo "unshare $*"; }
    '"$(sed -n '/^arch-chroot() {/,/^}/p' "$ORCH/archinstall.sh")"'
    arch-chroot /mnt limine-update
  ')
  [[ $out == "unshare --mount --propagation private -- arch-chroot /mnt limine-update" ]] || rc=1
  PATH="$d:$PATH" bash -c '
    '"$(sed -n '/^arch-chroot() {/,/^}/p' "$ORCH/archinstall.sh")"'
    ORCH_CHROOT_NO_UNSHARE=1 arch-chroot /mnt limine-update
  '
  grep -qx "real /mnt limine-update" "$d/calls" || rc=1
  rm -rf "$d"
  return "$rc"
}
check "chroots run in private mount namespaces, with a direct fallback" chroot_namespace_wrapper

# The property the deferred-encrypted flavor of that phase depends on: the
# generated LUKS passphrase is generated once and reused by every later
# context rebuild — two separate processes must agree on it.
passphrase_deterministic() {
  local d p1 p2
  d=$(mktemp -d) || return 1
  printf '{"disk_config": {"config_type": "default_layout", "device_modifications": [], "disk_encryption": {"encryption_type": "luks"}}, "omarchy_install": {"defer_provisioning": true}}' >"$d/config.json"
  touch "$d/marker"
  ctx_pass() {
    env OMARCHY_INSTALL_CONFIG="$d/config.json" OMARCHY_INSTALL_CREDS="$d/absent" \
      OMARCHY_INSTALL_DEFER_PROVISIONING_FILE="$d/marker" OMARCHY_INSTALL_STATE_DIR="$d/state" \
      OMARCHY_ARCHINSTALL_LIB="$ROOT/archinstall-bash/lib" bash -c \
      "source '$ORCH/main.sh' && ctx_from_env >/dev/null 2>&1 && jq -r .encryption_password \"\$CTX_STATE_DIR/provisioning-user_credentials.json\""
  }
  p1=$(ctx_pass); p2=$(ctx_pass)
  rm -rf "$d"
  [[ -n $p1 && $p1 == "$p2" ]]
}
check "the generated passphrase is deterministic across processes" passphrase_deterministic

if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'the install phase hosting behaves\n'
