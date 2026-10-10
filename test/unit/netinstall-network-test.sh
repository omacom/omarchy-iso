#!/bin/bash
#
# Unit tests for the configurator's network step (configs/airootfs/usr/share/
# omarchy-iso/network.sh), the one netinstall media cannot install without.
#
# Every case runs in a sandbox with pacman, iwctl and gum stubbed: pacman's
# answers are dealt from a queue so a test can say when the mirrors start
# answering, iwctl prints a table shaped like the real one and records what it
# was asked to connect to, and gum deals its answers from a queue so a test can
# say what the user chooses and types. The step is always called in a subshell,
# because abort() exits.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
NETWORK="$ROOT/configs/airootfs/usr/share/omarchy-iso/network.sh"

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

stubs="$work/stubs"
mkdir -p "$stubs" "$work/sysfs/class/net"

export TEST_LOG="$work/log"
export GUM_QUEUE="$work/gum-queue"
export IWCTL_LOG="$work/iwctl-log"
export PACMAN_QUEUE="$work/pacman-queue"
export PACMAN_LAST="$work/pacman-last"

reset_logs() {
  : >"$TEST_LOG"
  : >"$IWCTL_LOG"
  : >"$GUM_QUEUE"
  : >"$PACMAN_LAST"
}

# One exit code per pacman call, left to right; the last one repeats. 0 means
# the mirrors answered, 1 means they did not.
set_mirrors() {
  printf '%s\n' "$@" >"$PACMAN_QUEUE"
  : >"$PACMAN_LAST"
}

cat >"$stubs/pacman" <<'STUB'
#!/bin/bash
code=""
if [[ -s $PACMAN_QUEUE ]]; then
  code=$(head -n 1 "$PACMAN_QUEUE")
  sed -i '1d' "$PACMAN_QUEUE"
  printf '%s\n' "$code" >"$PACMAN_LAST"
elif [[ -s $PACMAN_LAST ]]; then
  code=$(head -n 1 "$PACMAN_LAST")
else
  code=1
fi
exit "$code"
STUB

cat >"$stubs/iwctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$IWCTL_LOG"

case "$*" in
*get-networks*)
  # Shaped like iwd's own table, colours included.
  printf '\n'
  printf '%s\n' '                              Available networks'
  printf '%s\n' '--------------------------------------------------------------------------------'
  printf '      %s\n' 'Network name                      Security            Signal'
  printf '%s\n' '--------------------------------------------------------------------------------'
  printf '\033[36m      CasaVerde                         psk                 ****\033[0m\n'
  printf '\033[36m      Cafe Guest                        open                ***\033[0m\n'
  printf '\033[36m      CasaVerde                         psk                 **\033[0m\n'
  exit 0
  ;;
esac

if [[ $* == *connect* ]]; then
  connected="${!#}"
  [[ ${IWCTL_REJECT_SSID:-} == "$connected" ]] && exit 1
  # The join worked, so the mirrors now answer.
  printf '0\n' >>"$PACMAN_QUEUE"
  exit 0
fi

exit 0
STUB

cat >"$stubs/gum" <<'STUB'
#!/bin/bash
# Answers are dealt from a queue, so a test says what the user chooses, types
# or confirms, in order.
answer() {
  [[ -s $GUM_QUEUE ]] || return 1
  value=$(head -n 1 "$GUM_QUEUE")
  sed -i '1d' "$GUM_QUEUE"
  printf '%s' "$value"
}

case ${1:-} in
choose | input)
  value=$(answer) || exit 1
  printf '%s\n' "$value" >>"$TEST_LOG"
  printf '%s\n' "$value"
  ;;
confirm)
  value=$(answer) || exit 1
  printf '%s\n' "$value" >>"$TEST_LOG"
  [[ $value == yes ]]
  ;;
*) : ;;
esac
STUB

chmod +x "$stubs"/*
export PATH="$stubs:$PATH"

# shellcheck disable=SC1090
source "$NETWORK"

# The sourced file takes its paths once, at load; the sandbox points them at
# itself the same way, before anything uses them.
MEDIA_MODE_FILE="$work/omarchy_media"
PACMAN_CONF="$work/pacman.conf"
NETWORK_CHECK_DB="$work/netcheck"
SYSFS_NET="$work/sysfs/class/net"
printf '[options]\n' >"$PACMAN_CONF"

# ── which medium asks at all ────────────────────────────────────────────────
printf 'offline\n' >"$MEDIA_MODE_FILE"
installs_from_network && fail "offline media does not install from the network"
printf 'netinstall\n' >"$MEDIA_MODE_FILE"
installs_from_network || fail "netinstall media installs from the network"
rm -f "$MEDIA_MODE_FILE"
installs_from_network && fail "an ISO with no marker is not netinstall media"

pass "only netinstall media ask for a connection"

# ── the step itself ─────────────────────────────────────────────────────────

# UI helpers belong to the configurator; the step only calls them.
run_step() {
  (
    step() { :; }
    say() { printf 'say: %s\n' "$*" >>"$TEST_LOG"; }
    notice() { :; }
    abort() {
      printf 'abort: %s\n' "$*" >>"$TEST_LOG"
      exit 1
    }
    network_step >/dev/null
  )
}

# 1. Offline media never even look, whatever the network is doing.
printf 'offline\n' >"$MEDIA_MODE_FILE"
reset_logs
set_mirrors 1
run_step || fail "offline media step returns success"
[[ ! -s $TEST_LOG ]] || fail "offline media never prompt" "$(cat "$TEST_LOG")"

# 2. netinstall on a machine that is already online: no questions.
printf 'netinstall\n' >"$MEDIA_MODE_FILE"
reset_logs
set_mirrors 0
run_step || fail "an online machine passes the step"
[[ ! -s $TEST_LOG ]] || fail "an online machine is never prompted" "$(cat "$TEST_LOG")"

pass "the step is invisible unless the connection is actually missing"

# 3. No wireless interface: ask for a cable, and take Retry as an answer.
reset_logs
set_mirrors 1 0
printf 'yes\n' >"$GUM_QUEUE"
run_step || fail "a cable plugged in during the retry passes the step"
grep -q '^yes$' "$TEST_LOG" || fail "the retry prompt is asked" "$(cat "$TEST_LOG")"

# 4. No cable and no patience: the step refuses to continue.
reset_logs
set_mirrors 1
printf 'no\n' >"$GUM_QUEUE"
if run_step; then fail "quitting without a connection fails the step"; fi
grep -q '^abort: This ISO needs a network connection to install.$' "$TEST_LOG" ||
  fail "the abort names the reason" "$(cat "$TEST_LOG")"

pass "a machine with no radio is told to plug in, and cannot proceed without it"

# 5. Wireless available: the scanned list is offered, the password is asked for
#    and reaches iwctl, and the step returns once the mirrors answer.
mkdir -p "$work/sysfs/class/net/wlan0/wireless"
reset_logs
set_mirrors 1
printf 'CasaVerde\ncorrect horse\n' >"$GUM_QUEUE"
run_step || fail "joining a network passes the step"
grep -q '^CasaVerde$' "$TEST_LOG" ||
  fail "the scanned SSIDs are offered, without duplicates or a header" "$(cat "$TEST_LOG")"
grep -q -- '--passphrase correct horse station wlan0 connect CasaVerde' "$IWCTL_LOG" ||
  fail "the password reaches iwctl for the chosen network" "$(cat "$IWCTL_LOG")"

pass "a wireless machine can be brought online from the wizard"

# 6. A join that fails is reported and the wizard asks again.
reset_logs
set_mirrors 1
printf 'CasaVerde\nwrong\nQuit to shell\n' >"$GUM_QUEUE"
export IWCTL_REJECT_SSID="CasaVerde"
if run_step; then fail "giving up on Wi-Fi fails the step"; fi
grep -q 'say: Could not join CasaVerde' "$TEST_LOG" ||
  fail "a failed join is reported" "$(cat "$TEST_LOG")"
[[ $(grep -c 'connect CasaVerde' "$IWCTL_LOG") == 1 ]] ||
  fail "the join is attempted once per password" "$(cat "$IWCTL_LOG")"
unset IWCTL_REJECT_SSID

pass "a wrong password is reported and re-asked"

# 7. A wireless interface is found through the kernel, not through iwd.
printf '' >"$work/sysfs/class/net/wlan0/bogus"
[[ $(wireless_device) == wlan0 ]] || fail "the wireless device is found in sysfs"
rm -rf "$work/sysfs/class/net/wlan0"
if wireless_device >/dev/null; then fail "no wireless interface reports none"; fi
mkdir -p "$work/sysfs/class/net/wlan0/wireless"

# 8. The scan list is what iwd prints, stripped of colour and duplicates.
mapfile -t scanned < <(wifi_networks wlan0)
[[ ${#scanned[@]} == 2 ]] || fail "duplicate SSIDs collapse to one each" "${scanned[*]}"
[[ ${scanned[0]} == "Cafe Guest" && ${scanned[1]} == "CasaVerde" ]] ||
  fail "SSIDs survive as printed, an SSID with a space included" "${scanned[*]}"

pass "iwd's table is read for what it is: names, once each"
