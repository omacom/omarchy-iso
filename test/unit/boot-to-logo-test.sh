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
LUKS_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-luks-calibrate.service"
KEYRING_UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-target-keyring-early.service"
grep -q '^Before=omarchy-luks-calibrate\.service omarchy-mirror-verify\.service omarchy-root-image-verify\.service$' "$GATE_UNIT" \
  || fail "omarchy-greeter-ready.service must order before calibration and verify units"
grep -q '^Type=oneshot$' "$LUKS_UNIT" \
  || fail "omarchy-luks-calibrate.service must be Type=oneshot so downstream units wait for calibration to exit"
grep -q '^RemainAfterExit=' "$LUKS_UNIT" \
  && fail "omarchy-luks-calibrate.service must not set RemainAfterExit (wait helpers check inactive state)"
grep -q '^After=omarchy-greeter-ready\.service$' "$LUKS_UNIT" \
  || fail "omarchy-luks-calibrate.service must run immediately after omarchy-greeter-ready.service"
grep -q '^ConditionPathExists=!/run/omarchy-iso/skip-luks-calibrate$' "$LUKS_UNIT" \
  || fail "omarchy-luks-calibrate.service must skip when /run/omarchy-iso/skip-luks-calibrate exists"

AUTO_SCRIPT="$ROOT/configs/airootfs/root/.automated_script.sh"
cidata_line=$(grep -vnE '^[[:space:]]*#' "$AUTO_SCRIPT" | grep "omarchy-cidata-load" | head -1 | cut -d: -f1)
skip_line=$(grep -vnE '^[[:space:]]*#' "$AUTO_SCRIPT" | grep "configure_luks_calibration_for_cidata" | tail -1 | cut -d: -f1)
ready_line=$(awk -v s="$cidata_line" 'NR > s && !/^[[:space:]]*#/ && /signal_greeter_ready/ { print NR; exit }' "$AUTO_SCRIPT")
(( cidata_line < skip_line && skip_line < ready_line )) \
  || fail ".automated_script.sh must evaluate cidata encryption before signal_greeter_ready (cidata=$cidata_line skip=$skip_line ready=$ready_line)"

cidata_dir="$fixture/cidata-root"
mkdir -p "$cidata_dir"
skip_file="$fixture/skip-luks-calibrate"
helpers_file="$fixture/cidata-helpers.sh"
awk '/^cidata_install_is_encrypted\(\)/,/^signal_greeter_ready\(\)/ { if (!/^signal_greeter_ready\(\)/) print }' "$AUTO_SCRIPT" >"$helpers_file"
bash -euo pipefail -c '
  source "$1"
  cidata_dir=$2
  export OMARCHY_SKIP_LUKS_CALIBRATE_FILE=$3
  systemctl() { :; }

  printf "false\n" >"$cidata_dir/user_encrypt_installation.txt"
  printf "{\"disk_config\": {}}\n" >"$cidata_dir/user_configuration.json"
  configure_luks_calibration_for_cidata "$cidata_dir"
  [[ -e $OMARCHY_SKIP_LUKS_CALIBRATE_FILE ]] || { echo "expected skip marker for unencrypted cidata" >&2; exit 1; }

  printf "true\n" >"$cidata_dir/user_encrypt_installation.txt"
  configure_luks_calibration_for_cidata "$cidata_dir"
  [[ ! -e $OMARCHY_SKIP_LUKS_CALIBRATE_FILE ]] || { echo "expected skip marker removed for encrypted cidata" >&2; exit 1; }

  rm -f "$cidata_dir/user_encrypt_installation.txt"
  printf "{\"disk_config\": {\"disk_encryption\": {\"encryption_type\": \"luks\"}}}\n" >"$cidata_dir/user_configuration.json"
  configure_luks_calibration_for_cidata "$cidata_dir"
  [[ ! -e $OMARCHY_SKIP_LUKS_CALIBRATE_FILE ]] || { echo "expected skip marker absent for disk_encryption cidata" >&2; exit 1; }

  printf "{\"omarchy_install\": {\"free_space_plan\": {\"encrypt\": true}}}\n" >"$cidata_dir/user_configuration.json"
  configure_luks_calibration_for_cidata "$cidata_dir"
  [[ ! -e $OMARCHY_SKIP_LUKS_CALIBRATE_FILE ]] || { echo "expected skip marker absent for encrypted free_space_plan" >&2; exit 1; }

  printf "{\"omarchy_install\": {\"free_space_plan\": {\"encrypt\": false}}}\n" >"$cidata_dir/user_configuration.json"
  configure_luks_calibration_for_cidata "$cidata_dir"
  [[ -e $OMARCHY_SKIP_LUKS_CALIBRATE_FILE ]] || { echo "expected skip marker for unencrypted free_space_plan" >&2; exit 1; }
' _ "$helpers_file" "$cidata_dir" "$skip_file" || fail "cidata encryption detection failed"
grep -q '^Before=omarchy-mirror-verify\.service omarchy-root-image-verify\.service$' "$LUKS_UNIT" \
  || fail "omarchy-luks-calibrate.service must finish before verify units start"
grep -q '^After=omarchy-greeter-ready\.service omarchy-luks-calibrate\.service$' "$MIRROR_UNIT" \
  || fail "omarchy-mirror-verify.service must order after greeter-ready and luks-calibrate"
grep -q '^After=omarchy-greeter-ready\.service omarchy-luks-calibrate\.service$' "$IMAGE_UNIT" \
  || fail "omarchy-root-image-verify.service must order after greeter-ready and luks-calibrate"
grep -q '^After=omarchy-luks-calibrate\.service$' "$KEYRING_UNIT" \
  || fail "omarchy-target-keyring-early.service should overlap USB verification once luks-calibrate finishes"

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
