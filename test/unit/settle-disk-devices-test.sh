#!/bin/bash
#
# Tests for settle_disk_devices() and O_RDONLY sfdisk partition-table reads in
# disk-partitioning.sh:
#   - settle_disk_devices() probes strictly O_RDONLY (flags & 3 == 0), never
#     triggers on fast settles or while another holder locks the disk, triggers
#     `udevadm trigger --action=change "$disk"` when stranded, bounds triggers,
#     and falls back to plain `udevadm settle` on non-block paths.
#   - _read_partition_table() / partition_numbers() / partition_size_bytes()
#     parse sfdisk -d accurately for empty GPT, holey GPT, 1 TiB+ sizes (no
#     scientific notation), 4Kn sectors, NVMe pN and sd N nodes, and MBR.
#   - create_partition() sets GPT partition names inline in mkpart (no extra
#     `parted name` O_RDWR call) and never runs mid-creation partprobe/settle.

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

# 6. sfdisk -d parsing: NVMe pN, 1 TiB+ exact integer bytes, 4Kn, empty GPT, MBR.
_partition_table_use_sfdisk() { return 0; }

sfdisk() {
  cat <<'DUMP'
label: gpt
device: /dev/nvme0n1
unit: sectors
sector-size: 512

/dev/nvme0n1p1 : start=        2048, size=     4194304, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EXIST_ESP"
/dev/nvme0n1p4 : start=     4196352, size=  2147483648, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="OMARCHY_ROOT"
DUMP
}
check "sfdisk nvme partition numbers" "1 4" "$(partition_numbers /dev/nvme0n1 | tr "\n" " " | sed "s/ \$//")"
check "sfdisk nvme 1TiB exact integer bytes" "1099511627776" "$(partition_size_bytes /dev/nvme0n1 4)"

sfdisk() {
  cat <<'DUMP'
label: gpt
device: /dev/sda
unit: sectors
sector-size: 4096

/dev/sda2 : start= 256, size= 524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
DUMP
}
check "sfdisk 4Kn sd partition number" "2" "$(partition_numbers /dev/sda)"
check "sfdisk 4Kn sd partition size" "2147483648" "$(partition_size_bytes /dev/sda 2)"

sfdisk() {
  cat <<'DUMP'
label: gpt
device: /dev/vda
unit: sectors
sector-size: 512
DUMP
}
check "sfdisk empty gpt has no partitions" "" "$(partition_numbers /dev/vda)"

sfdisk() {
  cat <<'DUMP'
label: dos
device: /dev/sda
unit: sectors
sector-size: 512

/dev/sda1 : start= 2048, size= 409600, type=83
DUMP
}
check "sfdisk mbr partition number" "1" "$(partition_numbers /dev/sda)"
check "sfdisk mbr partition size" "209715200" "$(partition_size_bytes /dev/sda 1)"
unset -f sfdisk

# 7. Real sfdisk + parted roundtrip on a GPT image: create_partition sets GPT
#    name inline in mkpart (no extra parted name call) and never runs partprobe
#    or udevadm settle mid-creation.
if command -v parted >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1; then
  IMG="$WORK/gpt.img"
  MIB=$((1024 * 1024))
  truncate -s 2G "$IMG"
  command parted --script "$IMG" mklabel gpt
  command parted --script "$IMG" mkpart one ext4 1MiB 100MiB
  created_parts=()
  PARTED_LOG="$WORK/parted.log"
  : >"$PARTED_LOG"
  parted() {
    echo "parted $*" >>"$PARTED_LOG"
    command parted "$@"
  }
  create_partition "$IMG" "$((200 * MIB))" "$((400 * MIB))" fat32 OMARCHY_EFI
  check "create_partition via sfdisk reads succeeded" "0" "$?"
  check "create_partition assigned slot 2" "2" "$created_partition_number"
  check "create_partition ran exactly 1 parted call on GPT" "1" "$(wc -l <"$PARTED_LOG" | tr -d " ")"
  check "create_partition passed GPT name inline to mkpart" "yes" \
    "$(grep -q "mkpart OMARCHY_EFI fat32 " "$PARTED_LOG" && echo yes || echo no)"
  check "GPT name recorded on disk" "yes" \
    "$(sfdisk -d "$IMG" | grep -q 'name="OMARCHY_EFI"' && echo yes || echo no)"

  # sfdisk read failure before mkpart must refuse creation (never mistaking an
  # existing partition for the new one).
  created_parts=()
  sfdisk() { return 1; }
  create_partition "$IMG" "$((500 * MIB))" "$((700 * MIB))" btrfs OMARCHY_ROOT
  check "create_partition refuses when sfdisk before-read fails" "1" "$?"
  check "nothing tracked when sfdisk before-read fails" "0" "${#created_parts[@]}"
  unset -f sfdisk

  # MBR (dos) disk must still pass "primary" to parted mkpart (not $name).
  MBR="$WORK/mbr.img"
  truncate -s 2G "$MBR"
  command parted --script "$MBR" mklabel msdos
  created_parts=()
  : >"$PARTED_LOG"
  create_partition "$MBR" "$((10 * MIB))" "$((210 * MIB))" fat32 OMARCHY_EFI
  check "create_partition on MBR succeeded" "0" "$?"
  check "create_partition on MBR passed primary to mkpart" "yes" \
    "$(grep -q "mkpart primary fat32 " "$PARTED_LOG" && echo yes || echo no)"
  unset -f parted
fi

create_body=$(awk "/^create_partition\(\) \{/,/^\}/" "$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh" | grep -vE "^[[:space:]]*#")
check "create_partition has no partprobe" "0" "$(grep -c "partprobe" <<<"$create_body" || true)"
check "create_partition has no udevadm settle" "0" "$(grep -c "udevadm settle" <<<"$create_body" || true)"


# 8. write_free_space_config emits the exact free_space_plan JSON schema (both
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
