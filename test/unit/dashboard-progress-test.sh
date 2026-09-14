#!/bin/bash
#
# The dashboard's weights progress model, driven through a scripted playback
# of the real unit roster: a stub systemctl answers each frame's poll and the
# test steps NOW by hand, so every position is deterministic. What matters:
# the linear walk reproduces the old band table's positions, concurrent
# phases both contribute credit in the same frame, the sum is monotone
# through a phase completing, and the terminal latch is the only way to
# 1000.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

fails=0
check() { # desc, expected, actual
  local desc=$1 want=$2 got=$3
  if [[ $got != "$want" ]]; then
    echo "FAIL: $desc (want '$want', got '$got')"; fails=1; return
  fi
  echo "ok: $desc"
}
check_test() { # desc, test-args...
  local desc=$1
  shift
  if test "$@"; then echo "ok: $desc"; else echo "FAIL: $desc (test $*)"; fails=1; fi
}

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT
printf 'OMARCHY\n' >"$BOX/logo.txt"
awk '/^\[\[ -e \$TTY_PATH \]\] \|\| exit 2$/ { exit } { print }' "$DASHBOARD" >"$BOX/defs.sh"

# The playback: UNIT_MODE[unit] = active|activating|inactive, UNIT_STATUS
# holds one unit's StatusText. The stub renders systemctl show's block
# format from them.
declare -A UNIT_MODE=()
UNIT_STATUS_FOR="" UNIT_STATUS_TEXT=""
systemctl() {
  local u first=1
  for u in "$@"; do
    [[ $u == omarchy-install-*.service ]] || continue
    (( first )) || echo
    first=0
    echo "ActiveState=${UNIT_MODE[$u]:-inactive}"
    if [[ $u == "$UNIT_STATUS_FOR" ]]; then
      echo "StatusText=$UNIT_STATUS_TEXT"
    else
      echo "StatusText="
    fi
  done
}

# shellcheck disable=SC1091
OMARCHY_PATH="$BOX" OMARCHY_INSTALL_UNITS_DIR="$ROOT/configs/airootfs/etc/systemd/system" \
  source "$BOX/defs.sh" "$BOX/log" -- true 2>/dev/null

check "the roster covers the shipped graph" 17 "$PHASE_TOTAL"
check "the weights and the virtual start fill the bar exactly" 990 "$PHASE_W_SUM"

set_active() { local u; for u in "$@"; do UNIT_MODE[$u]=active; done; }

# ── pre-graph: the virtual starting phase creeps from the base ──────────────
NOW=100
install_progress
check_test "pre-graph position starts at the base" "$PROGRESS_PM" -ge 10 -a "$PROGRESS_PM" -le 12
NOW=120
install_progress
PRE_LATE=$PROGRESS_PM
check_test "pre-graph position approaches its share asymptotically" "$PRE_LATE" -gt 20 -a "$PRE_LATE" -lt 25

# ── linear equivalence: prefix sums are the old band floors ─────────────────
set_active omarchy-install-prepare-live.service omarchy-install-prepare-target.service
UNIT_MODE[omarchy-install-disk.service]=activating
UNIT_STATUS_FOR=omarchy-install-disk.service UNIT_STATUS_TEXT="progress=0.4231"
NOW=130
install_progress
check "the linear mid-install position matches the old band walk" 66 "$PROGRESS_PM"
check "the dashboard authors the session log's phase marker" \
  "1" "$(grep -c '› Preparing disk layout' "$BOX/log" 2>/dev/null)"

# ── monotone through a completion: partial credit becomes full weight ───────
NOW=160
install_progress
BEFORE=$PROGRESS_PM
UNIT_MODE[omarchy-install-disk.service]=active
UNIT_STATUS_FOR="" UNIT_STATUS_TEXT=""
UNIT_MODE[omarchy-install-image.service]=activating
install_progress
check_test "a completing phase never moves the bar backwards" "$PROGRESS_PM" -ge "$BEFORE"

# ── the unpack rides its own progress signal ────────────────────────────────
UNIT_STATUS_FOR=omarchy-install-image.service UNIT_STATUS_TEXT="progress=0.5000"
install_progress
HALF_STREAM=$PROGRESS_PM
UNIT_STATUS_TEXT="progress=0.9000"
install_progress
check_test "stream progress drives the unpack's credit" "$PROGRESS_PM" -gt "$HALF_STREAM"

# ── concurrency: two activating phases both contribute in one frame ─────────
set_active omarchy-install-image.service omarchy-install-strap.service \
  omarchy-install-base.service omarchy-install-hibernation.service \
  omarchy-install-system.service omarchy-install-provisioning.service
UNIT_STATUS_FOR="" UNIT_STATUS_TEXT=""
UNIT_MODE[omarchy-install-limine.service]=activating
NOW=200
install_progress
FLOOR_ONE=$PROGRESS_PM
solo_gain_probe() { # measures the 10s gain with limine alone vs limine+user
  NOW=210
  install_progress
  SOLO=$((PROGRESS_PM - FLOOR_ONE))
  # rewind to the fan floor and run the same 10s with both phases active
  POS=$FLOOR_ONE PROGRESS_PM=$FLOOR_ONE
  unset "PHASE_T0S[9]" "PHASE_T0S[10]" 2>/dev/null || true
  PHASE_T0S=()
  UNIT_MODE[omarchy-install-user.service]=activating
  NOW=200
  install_progress
  NOW=210
  install_progress
  PAIR=$((PROGRESS_PM - FLOOR_ONE))
}
solo_gain_probe
check_test "concurrent phases move the bar faster than one alone" "$PAIR" -gt "$SOLO"

# ── only the terminal latch reaches 1000 ────────────────────────────────────
for u in "${PHASE_UNITS[@]}"; do UNIT_MODE[$u]=active; done
UNIT_MODE[omarchy-install-factory-snapshot.service]=activating
NOW=300
install_progress
check_test "everything-but-the-terminal stays short of full" "$PROGRESS_PM" -lt 1000
UNIT_MODE[omarchy-install-factory-snapshot.service]=active
install_progress
check "the terminal latch completes the bar" 1000 "$PROGRESS_PM"

# ── the installed-in line reads the installer's own journal milestones ──────
journalctl() {
  [[ $* == *"-t omarchy-install-milestone"* ]] || return 0
  printf '1756640000.100000 host omarchy-install-milestone[10]: -----BEGIN OMARCHY INSTALL-----\n'
  printf '1756640062.400000 host omarchy-install-milestone[99]: -----END OMARCHY INSTALL-----\n'
}
check "the displayed duration is the start-to-finished journal span" "1m 2s" "$(install_duration)"
journalctl() { :; }
DASH_T0=0
check "no milestones and no clock falls back to the log parse (empty here)" "" "$(install_duration)"

if (( fails )); then
  echo "dashboard progress model: FAILED"
  exit 1
fi
echo "ok: the weights model walks the linear graph and sums the fan"
