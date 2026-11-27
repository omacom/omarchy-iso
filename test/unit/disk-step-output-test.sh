#!/bin/bash
#
# disk_step() must keep a successful command off the screen. The installer
# tees stdout to the tty as well as to the install log, so printing the output
# of disk helpers flashes text between configurator screens. On success the
# output belongs in the log only; on failure it belongs in both, because the
# next screen is the abort message and the user needs to see why.
#
# Also asserts the configurator no longer runs LUKS format/open directly now
# that free-space execution lives inside orchestrator/free_space.py.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=SCRIPTDIR/../../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
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

# The failure lands on the abort screen, where the configurator's text is
# indented by PADDING_LEFT; the command's own lines are indented with it.
screen=$( (PADDING_LEFT=4 disk_step "a padded failure" sh -c "echo first >&2; echo second >&2; exit 3") 2>/dev/null)
check "failure output is padded like the configurator" "    first|    second" "$(tr "\n" "|" <<<"$screen" | sed "s/|\$//")"

# A line longer than the width left beside the padding wraps inside it.
screen=$( (COLUMNS=30 PADDING_LEFT=4 disk_step "a long failure" sh -c "echo abcdefghijklmnopqrstuvwxyz0123456789 >&2; exit 3") 2>/dev/null)
check "a long failure line wraps inside the padding" "    abcdefghijklmnopqrstuvwxyz|    0123456789" "$(tr "\n" "|" <<<"$screen" | sed "s/|\$//")"

# disk_step passes stdin through byte for byte without trailing newlines and
# keeps command output off the screen on success.
: >"$OMARCHY_INSTALL_LOG_FILE"
screen=$(disk_step "reads a passphrase" sh -c 'printf "got %s bytes\n" "$(wc -c | tr -d " ")"; echo notice >&2' < <(printf "%s" "s3cret"))
check "a passphrase on stdin leaves the screen alone" "" "$screen"
check "the command read it without a newline" "got 6 bytes notice" \
  "$(tr "\n" " " <"$OMARCHY_INSTALL_LOG_FILE" | sed "s/ \$//")"

# Free-space LUKS execution moved into orchestrator/free_space.py; configurator
# must not run omarchy-luks-calibrate format or cryptsetup open directly.
configurator="$ROOT/configs/airootfs/root/configurator"
statements=$(grep -vE '^[[:space:]]*#' "$configurator" |
  grep -E 'omarchy-luks-calibrate format|cryptsetup open ' || true)
check "configurator has no direct LUKS format/open commands" "0" "$(grep -c . <<<"$statements" || true)"

unset OMARCHY_INSTALL_LOG_FILE
screen=$(disk_step "no log file" echo visible)
check "without a log file the output is not lost" "visible" "$screen"

((failures == 0)) && echo "PASS" || { echo "FAILED: $failures"; exit 1; }
