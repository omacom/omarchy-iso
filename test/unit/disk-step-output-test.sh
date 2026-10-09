#!/bin/bash
#
# disk_step() must keep a successful command off the screen. The installer
# tees stdout to the tty as well as to the install log, so printing the output
# of mkfs.btrfs, four "btrfs subvolume create" and mkfs.fat flashes ~27 lines
# of text between two configurator screens. On success the
# output belongs in the log only; on failure it belongs in both, because the
# next screen is the abort message and the user needs to see why.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

WORK=$(mktemp -d)
trap "rm -rf \"\$WORK\"" EXIT
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf "  ok   %s\n" "$label"
  else
    printf "  FAIL %s: expected [%s], got [%s]\n" "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

export OMARCHY_INSTALL_LOG_FILE="$WORK/install.log"
: >"$OMARCHY_INSTALL_LOG_FILE"

screen=$(disk_step "a quiet success" sh -c "echo chatty; echo also-chatty >&2")
check "success prints nothing" "" "$screen"
check "success is logged, stderr included" "chatty also-chatty" \
  "$(tr "\n" " " <"$OMARCHY_INSTALL_LOG_FILE" | sed "s/ \$//")"

: >"$OMARCHY_INSTALL_LOG_FILE"
screen=$( (disk_step "a loud failure" sh -c "echo why-it-broke >&2; exit 3") 2>/dev/null)
check "failure prints the output" "why-it-broke" "$screen"

unset OMARCHY_INSTALL_LOG_FILE
screen=$(disk_step "no log file" echo visible)
check "without a log file the output is not lost" "visible" "$screen"

((failures == 0)) && echo "PASS" || { echo "FAILED: $failures"; exit 1; }
