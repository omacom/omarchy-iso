#!/bin/bash
#
# Live boot-to-logo optimizations:
# - omarchy-greeter-ready.service holds medium verification until the greeter
#   draws its logo (or a non-interactive boot starts), with a bounded fallback.
# - /root/.zprofile skips /etc/zsh/zshrc (grml-zsh-config + compinit) on tty1
#   autologin while keeping /root/.zlogin and full zsh on other VTs / SSH.
# - build-iso.sh drops unused iwd.service and ModemManager.service from live
#   multi-user.target.wants.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WAIT_TOOL="$ROOT/configs/airootfs/usr/local/bin/omarchy-wait-greeter-ready"
GATE_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-greeter-ready.service"
GATE_WANTED="$ROOT/configs/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-greeter-ready.service"
MIRROR_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-mirror-verify.service"
IMAGE_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-root-image-verify.service"
ZPROFILE="$ROOT/configs/airootfs/root/.zprofile"
AUTO="$ROOT/configs/airootfs/root/.automated_script.sh"
BUILD_ISO="$ROOT/builder/build-iso.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Unit wiring and profiledef permissions
[[ -x $WAIT_TOOL ]] || fail "omarchy-wait-greeter-ready missing or not executable"
[[ -f $GATE_UNIT ]] || fail "omarchy-greeter-ready.service missing"
[[ -L $GATE_WANTED && $(readlink "$GATE_WANTED") == ../omarchy-greeter-ready.service ]] \
  || fail "omarchy-greeter-ready.service not enabled in multi-user.target.wants"
grep -q '"/usr/local/bin/omarchy-wait-greeter-ready"\]="0:0:755"' "$ROOT/configs/profiledef.sh" \
  || fail "omarchy-wait-greeter-ready not registered in profiledef.sh"
grep -q '^Before=omarchy-mirror-verify\.service omarchy-root-image-verify\.service$' "$GATE_UNIT" \
  || fail "omarchy-greeter-ready.service does not order before verify units"
grep -q '^After=omarchy-greeter-ready\.service$' "$MIRROR_UNIT" \
  || fail "omarchy-mirror-verify.service missing After=omarchy-greeter-ready.service"
grep -q '^After=omarchy-greeter-ready\.service$' "$IMAGE_UNIT" \
  || fail "omarchy-root-image-verify.service missing After=omarchy-greeter-ready.service"

# 2. Immediate exit when marker already exists
marker="$fixture/already-ready"
echo "4.21" >"$marker"
OMARCHY_GREETER_READY_FILE="$marker" OMARCHY_GREETER_READY_TIMEOUT=5 "$WAIT_TOOL" \
  || fail "wait tool failed when marker already existed"

# 3. Unblocks promptly once marker appears asynchronously
async_marker="$fixture/async-ready"
(sleep 0.15; echo "5.00" >"$async_marker") &
writer=$!
OMARCHY_GREETER_READY_FILE="$async_marker" OMARCHY_GREETER_READY_TIMEOUT=5 OMARCHY_GREETER_READY_POLL=0.02 \
  "$WAIT_TOOL" || fail "wait tool failed waiting for async marker"
wait "$writer"
[[ -f $async_marker ]] || fail "wait tool exited before async marker appeared"

# 4. Falls through cleanly on timeout (headless / broken-VT fallback)
missing_marker="$fixture/never-ready"
OMARCHY_GREETER_READY_FILE="$missing_marker" OMARCHY_GREETER_READY_TIMEOUT=1 OMARCHY_GREETER_READY_POLL=0.05 \
  "$WAIT_TOOL" || fail "wait tool failed instead of falling through on timeout"

# 5. Non-interactive paths in .automated_script.sh release the gate
grep -q 'signal_greeter_ready' "$AUTO" || fail ".automated_script.sh never signals greeter-ready"
(( $(grep -c 'signal_greeter_ready$' "$AUTO") >= 3 )) \
  || fail ".automated_script.sh must release greeter-ready on recovery, oem, and cidata paths"

# 6. /root/.zprofile skips global rcs only on /dev/tty1 login
[[ -f $ZPROFILE ]] || fail "configs/airootfs/root/.zprofile missing"
grep -q '== /dev/tty1' "$ZPROFILE" || fail ".zprofile does not scope NO_GLOBAL_RCS to /dev/tty1"
grep -q 'setopt NO_GLOBAL_RCS' "$ZPROFILE" || fail ".zprofile does not set NO_GLOBAL_RCS"

# 7. build-iso.sh drops iwd.service and ModemManager.service from live boot
grep -q 'multi-user\.target\.wants/iwd\.service' "$BUILD_ISO" \
  || fail "build-iso.sh does not remove iwd.service from live multi-user.target.wants"
grep -q 'multi-user\.target\.wants/ModemManager\.service' "$BUILD_ISO" \
  || fail "build-iso.sh does not remove ModemManager.service from live multi-user.target.wants"

echo "ok - live boot-to-logo optimizations verified"
