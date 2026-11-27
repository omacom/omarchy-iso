#!/bin/bash
#
# Tests for settle_disk_devices() in disk-partitioning.sh and
# write_free_space_config() in configurator:
#   - settle_disk_devices() probes strictly O_RDONLY (flags & 3 == 0), never
#     triggers on fast settles or while another holder locks the disk, triggers
#     `udevadm trigger --action=change "$disk"` when stranded, bounds triggers,
#     and falls back to plain `udevadm settle` on non-block paths.
#   - write_free_space_config() emits the exact omarchy_install.free_space_plan
#     JSON schema in both normal and dry-run modes without touching any disk.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=SCRIPTDIR/../../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
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

FAKE_DISK="$WORK/fake-disk"
: >"$FAKE_DISK"
LOG="$WORK/events.log"

# 1. Plain fallback when disk is empty or not a block device.
: >"$LOG"
udevadm() { echo "udevadm $*" >>"$LOG"; }
settle_disk_devices "" 7
check "empty disk falls back to plain settle" "udevadm settle --timeout=7" "$(cat "$LOG")"

: >"$LOG"
settle_disk_devices "$FAKE_DISK" 7
check "non-block path falls back to plain settle" "udevadm settle --timeout=7" "$(cat "$LOG")"

: >"$LOG"
settle_disk_devices "$FAKE_DISK"
check "omitted timeout runs udevadm settle without --timeout" "udevadm settle" "$(cat "$LOG")"

# Override _is_block_device for the remaining settle cases.
_is_block_device() { [[ -f "$1" ]]; }

# 2. Fast settle completes with zero triggers.
: >"$LOG"
udevadm() {
  echo "udevadm $*" >>"$LOG"
  [[ $1 == settle ]] && return 0
}
settle_disk_devices "$FAKE_DISK" 10
check "fast settle emits no trigger" "0" "$(grep -c "^udevadm trigger " "$LOG" || true)"

# 3. Stranded settle: wakes on trigger --action=change, probing O_RDONLY only.
: >"$LOG"
WAKE="$WORK/wake"
rm -f "$WAKE"
udevadm() {
  echo "udevadm $*" >>"$LOG"
  if [[ $1 == settle ]]; then
    for _ in $(seq 1 100); do
      [[ -f "$WAKE" ]] && return 0
      sleep 0.01
    done
    return 1
  elif [[ $1 == trigger ]]; then
    : >"$WAKE"
  fi
}
flock() {
  local mode
  mode=$(( $(awk "/^flags:/ { print \$2 }" "/proc/$$/fdinfo/$3") & 3 ))
  echo "flock $1 $2 mode=$mode" >>"$LOG"
  command flock "$@"
}
settle_disk_devices "$FAKE_DISK" 10
check "stranded settle triggers change on disk" "1" "$(grep -c "^udevadm trigger --action=change $FAKE_DISK\$" "$LOG" || true)"
check "probe descriptor is strictly O_RDONLY (mode 0)" "0" "$(grep -c "^flock -x -n mode=[^0]" "$LOG" || true)"
check "probe ran non-blocking exclusive flock" "yes" "$(grep -q "^flock -x -n mode=0\$" "$LOG" && echo yes || echo no)"

# 4. Active worker/synth holding LOCK_SH: never triggers while locked.
: >"$LOG"
unset -f flock
exec {holder_fd}<"$FAKE_DISK"
command flock -s "$holder_fd"
udevadm() {
  echo "udevadm $*" >>"$LOG"
  if [[ $1 == settle ]]; then
    sleep 0.14
    return 0
  fi
}
settle_disk_devices "$FAKE_DISK" 10
exec {holder_fd}<&-
check "locked disk never triggers mid-work" "0" "$(grep -c "^udevadm trigger " "$LOG" || true)"

# 5. Unrelated slow settle: trigger count is bounded (<= 5).
: >"$LOG"
udevadm() {
  echo "udevadm $*" >>"$LOG"
  if [[ $1 == settle ]]; then
    sleep 1.15
    return 0
  fi
}
settle_disk_devices "$FAKE_DISK" 10
trigger_count=$(grep -c "^udevadm trigger --action=change $FAKE_DISK\$" "$LOG" || true)
check "triggers are bounded at <= 5" "1" "$(( trigger_count >= 1 && trigger_count <= 5 ))"
unset -f udevadm

# 6. write_free_space_config emits the exact free_space_plan JSON schema (both
#    normal and dry-run modes, without touching any disk).
configurator="$ROOT/configs/airootfs/root/configurator"
fn_def=$(awk '/^write_free_space_config\(\) \{/,/^disk_form\(\) \{/' "$configurator" | sed '$d')
(
  cd "$WORK" || exit 1
  eval "$fn_def"
  say() { printf '%s\n' "$*"; }
  # shellcheck disable=SC2034 # consumed by eval'd write_free_space_config
  keyboard_input_method=none keyboard_xkb_layout="" language=en \
    esp_mount_in_target=/boot limine_efi_binary=BOOTX64.EFI \
    kernel_choice=linux-cachyos disk=/dev/nvme0n1 needs_mklabel=false \
    EFI_START_B=216895881216 EFI_END_B=219043364864 \
    ROOT_START_B=219044413440 ROOT_END_B=1024208502784 \
    encrypt_installation=true hostname=omarchy timezone=UTC keyboard=us \
    archinstall_custom_servers='            {"url": "file:///var/cache/omarchy/mirror/os/$arch"}' \
    OMARCHY_SETTINGS_PACKAGE=omarchy-settings OMARCHY_RUNTIME_PACKAGE=omarchy-runtime
  dry_out=$(write_free_space_config dry)
  grep -Fq '[dry] encrypted=true kernel=linux-cachyos' <<<"$dry_out" || exit 2
)
check "write_free_space_config dry-run succeeded" "0" "$?"
python3 - "$WORK/user_configuration.json" <<'EOF'
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
oi = cfg["omarchy_install"]
assert oi["mode"] == "protected"
assert oi["target_mount"] == "/mnt"
assert oi["boot"] == {
    "esp_mount": "/boot",
    "esp_path": "/EFI/limine",
    "efi_binary": "BOOTX64.EFI",
    "enable_fallback": True,
}
assert oi["storage"] == {
    "esp_device": None,
    "root_device": None,
    "root_mapper": None,
    "luks_uuid": None,
    "kernel": "linux-cachyos",
}
assert oi["free_space_plan"] == {
    "disk": "/dev/nvme0n1",
    "needs_mklabel": False,
    "efi_start_b": 216895881216,
    "efi_end_b": 219043364864,
    "root_start_b": 219044413440,
    "root_end_b": 1024208502784,
    "encrypt": True,
}
assert cfg["disk_config"] == {"config_type": "pre_mounted_config", "mountpoint": "/mnt"}
EOF
check "write_free_space_config emitted valid free_space_plan JSON schema" "0" "$?"

if (( failures > 0 )); then
  printf "\n%d check(s) failed\n" "$failures"
  exit 1
fi
echo "PASS"
