# shellcheck shell=bash
# Disk partitioning helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never predict a partition number. parted fills the lowest
# free GPT slot, not "highest existing + 1", so any disk whose numbering has a
# hole — exactly what deleting a partition to free space leaves behind, which
# is what our own partition tool tells the user to do — hands back a number we
# did not choose. Everything below reads back what was actually created.
#
# Sourced, not executed. The configurator defines abort() and
# disk_abort_hook(); tests get the plain fallbacks.

# Partitions this run created, in creation order. rollback_created_parts()
# undoes exactly these and nothing else.
created_parts=()

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# Compute partition device path, handling NVMe/mmcblk's pN naming.
partition_path() {
  local _disk="$1" _num="$2"
  if [[ "$_disk" == *nvme* || "$_disk" == *mmcblk* ]]; then
    echo "${_disk}p${_num}"
  else
    echo "${_disk}${_num}"
  fi
}

# Overridable predicate: use O_RDONLY sfdisk on real block devices so reading
# the partition table never opens the disk/partitions O_RDWR (parted -ms print
# triggers ~11 udev events per call on a 4-partition disk; sfdisk -d triggers 0).
# Regular image files (e.g. partition-numbering-test.sh) keep parted -ms print.
_partition_table_use_sfdisk() {
  [[ -b "$1" ]] && command -v sfdisk >/dev/null 2>&1
}

# Read partition table metadata from disk: prints "LABEL <type>" on line 1
# followed by "<num> <size_bytes>" for each partition.
_read_partition_table() {
  local disk="$1" dump table
  if _partition_table_use_sfdisk "$disk"; then
    dump=$(sfdisk -d "$disk" 2>/dev/null) || return 1
    printf '%s\n' "$dump" | awk -v d="$disk" '
      BEGIN { sec = 512; label = "" }
      /^label:[[:space:]]*/ {
        label = $0
        sub(/^label:[[:space:]]*/, "", label)
        sub(/[[:space:]]*$/, "", label)
        next
      }
      /^sector-size:[[:space:]]*[0-9]+/ {
        s = $0
        sub(/^sector-size:[[:space:]]*/, "", s)
        sec = s + 0
        next
      }
      index($0, d) == 1 && index($0, " : ") > 0 {
        node = $1
        num = substr(node, length(d) + 1)
        sub(/^p/, "", num)
        if (num ~ /^[0-9]+$/ && match($0, /size=[[:space:]]*[0-9]+/)) {
          sz = substr($0, RSTART, RLENGTH)
          sub(/^size=[[:space:]]*/, "", sz)
          rows[++n] = sprintf("%s %.0f", num, (sz + 0) * sec)
        }
      }
      END {
        printf "LABEL %s\n", label
        for (i = 1; i <= n; i++) print rows[i]
      }
    '
  else
    table=$(parted -ms "$disk" unit B print 2>/dev/null) || return 1
    printf '%s\n' "$table" | awk -F: '
      NR == 2 { printf "LABEL %s\n", $6; next }
      NR >= 3 && $1 ~ /^[0-9]+$/ {
        sz = $4
        gsub(/B/, "", sz)
        printf "%s %s\n", $1, sz
      }
    '
  fi
}

# Partition numbers as the on-disk table reports them. Read straight from disk
# (sfdisk -d O_RDONLY on block devices, parted -ms print on image files) so
# discovery never depends on udev or the kernel having re-read the table yet.
partition_numbers() {
  local table
  table=$(_read_partition_table "$1") || return 1
  printf '%s\n' "$table" | awk 'NR > 1 { print $1 }'
}

partition_size_bytes() {
  local table
  table=$(_read_partition_table "$1") || return 1
  printf '%s\n' "$table" | awk -v n="$2" 'NR > 1 && $1 == n { print $2; exit }'
}

# The disk's partition table type ("gpt", "msdos", ...), or nothing on a disk
# with no table, which the free-space install answers with mklabel gpt over
# the whole disk: a partitioned disk taken for a blank one loses every
# partition. parted decides, because it is what runs mklabel and reads the
# table from the disk itself ("unknown" when there is none). blkid's probe and
# lsblk are witnesses after it, so a disk counts as blank only when none of the
# three finds a table. lsblk alone answers from udev's database, which has no
# PTTYPE for a disk udev has not finished probing, and both lsblk and blkid
# skip the table on a disk that carries a stale RAID member signature.
partition_table_type() {
  local pt_type
  pt_type=$(parted -ms "$1" print 2>/dev/null | sed -n 2p | cut -d: -f6)
  [[ $pt_type == unknown ]] && pt_type=""
  [[ -n $pt_type ]] || pt_type=$(blkid -p -s PTTYPE -o value "$1" 2>/dev/null || true)
  [[ -n $pt_type ]] || pt_type=$(lsblk -dno PTTYPE "$1" 2>/dev/null || true)
  printf '%s\n' "$pt_type"
}

# Fail loudly. The former version looped over sleep and returned its status,
# so a device that never appeared was indistinguishable from one that did.
wait_for_device() {
  for _ in $(seq 1 50); do
    [[ -b "$1" ]] && return 0
    udevadm settle 2>/dev/null || true
    [[ -b "$1" ]] && return 0
    sleep 0.2
  done
  return 1
}

# Overridable predicate so unit tests can exercise settle_disk_devices without
# root or real block device nodes.
_is_block_device() {
  [[ -b "$1" ]]
}

# True while pid is still running (and not an unreaped zombie).
_pid_running() {
  local pid="$1" stat_line rest
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r /proc/$pid/stat ]]; then
    read -r stat_line <"/proc/$pid/stat" 2>/dev/null || return 1
    rest="${stat_line##*) }"
    [[ ${rest%% *} != Z ]] || return 1
  fi
  return 0
}

# Wait for udev to finish processing events on a disk without stalling on
# systemd-udevd's (udev-synth) LOCK_EX vs (udev-worker) TRY_AGAIN=1 race.
# Closing a whole disk O_RDWR makes udevd fork (udev-synth), which takes
# LOCK_EX while partition workers try LOCK_SH. Workers that hit EAGAIN enter
# EVENT_LOCKED on udevd's 200 ms + 1 s retry timer, and (udev-synth) closes
# O_RDONLY (emitting no IN_CLOSE_WRITE), stranding udevadm settle until the
# timer fires. Probing with a non-blocking flock on an O_RDONLY descriptor
# (whose close never emits IN_CLOSE_WRITE or forks udev-synth) detects when
# no synth or worker holds the disk lock; if settle is still waiting, one
# `udevadm trigger --action=change "$disk"` runs a whole-disk worker whose
# completion immediately requeues the locked partition events.
# Wait up to $2 * 10 ms for $1 to exit; returns 0 once it exits, 1 if still alive.
_wait_pid_ticks() {
  local pid="$1" ticks="$2"
  while (( ticks > 0 )); do
    _pid_running "$pid" || return 0
    sleep 0.01
    ticks=$((ticks - 1))
  done
  _pid_running "$pid" || return 0
  return 1
}

settle_disk_devices() {
  local disk="${1:-}" timeout="${2:-10}"
  if [[ -z $disk ]] || ! _is_block_device "$disk"; then
    udevadm settle --timeout="$timeout" 2>/dev/null || true
    return 0
  fi

  udevadm settle --timeout="$timeout" 2>/dev/null &
  local settle_pid=$!
  local ticks probe_fd

  # Backoff schedule (60 ms, 120 ms, 250 ms, 250 ms, 250 ms) lets healthy
  # drains finish with zero extra events, while breaking a 200 ms + 1 s
  # EVENT_LOCKED timer stall once no synth/worker holds the whole-disk lock.
  for ticks in 6 12 25 25 25; do
    _wait_pid_ticks "$settle_pid" "$ticks" && break
    if { exec {probe_fd}<"$disk"; } 2>/dev/null; then
      if flock -x -n "$probe_fd" 2>/dev/null; then
        exec {probe_fd}<&-
        if _pid_running "$settle_pid"; then
          udevadm trigger --action=change "$disk" 2>/dev/null || true
        fi
      else
        exec {probe_fd}<&-
      fi
    fi
  done

  wait "$settle_pid" 2>/dev/null || true
}

_disk_abort() {
  if declare -F disk_abort_hook >/dev/null; then
    disk_abort_hook "$1"
  elif declare -F abort >/dev/null; then
    abort "$1"
  fi
  echo "Error: $1" >&2
  exit 1
}

# Run a disk-writing command, fold its stderr into stdout, and abort on a
# non-zero exit. The fold matters: .automated_script.sh tees stdout into
# /var/log/omarchy-install.log but sends stderr straight to the tty (gum draws
# its TUI there), so an unwrapped failure leaves no trace in the log the user
# uploads — and the configurator's next screen clears it off the display too.
#
# That same tee also reaches the tty, so a successful command's output goes to
# the log file alone: mkfs.btrfs, the subvolumes and mkfs.fat otherwise flash
# ~27 lines of text between two configurator screens.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  if [[ -n $output ]]; then
    if (( status == 0 )) && [[ -n ${OMARCHY_INSTALL_LOG_FILE:-} ]]; then
      printf '%s\n' "$output" >>"$OMARCHY_INSTALL_LOG_FILE"
    else
      # Indented like the configurator's own text (PADDING_LEFT), wrapped to
      # the width left beside it, so a long line does not wrap to column 0.
      local width=$(( ${TERM_WIDTH:-${COLUMNS:-80}} - ${PADDING_LEFT:-0} ))
      (( width < 20 )) && width=20
      printf '%s\n' "$output" | fold -w "$width" | sed "s/^/$(printf '%*s' "${PADDING_LEFT:-0}" '')/"
    fi
  fi
  (( status == 0 )) && return 0
  _disk_abort "$desc failed (exit $status)"
}

# Create one partition and report the number parted actually assigned.
# Returns non-zero without touching created_parts if anything looks wrong;
# the caller decides how loudly to fail.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before_table before label mkpart_arg after_table after num actual want tolerance

  created_partition_number=""

  # Both reads must succeed. If only the first failed, every existing
  # partition would look new, and one the size of the requested partition (an
  # earlier install's 2GiB ESP) would be taken for it and formatted.
  before_table=$(_read_partition_table "$disk") || return 1
  label=$(printf '%s\n' "$before_table" | awk 'NR == 1 { print $2 }')
  before=$(printf '%s\n' "$before_table" | awk 'NR > 1 { print $1 }')

  # On GPT, parted's first mkpart argument is the partition name itself, so
  # passing $name sets it in the same call instead of a second O_RDWR parted
  # invocation. On MBR (dos/msdos) the argument is the partition type ("primary").
  if [[ $label == gpt && -n $name ]]; then
    mkpart_arg="$name"
  else
    mkpart_arg="primary"
  fi

  # parted's end is the last byte of the partition, so end - 1: the partition
  # is exactly end - start, which LUKS needs to use 4096-byte sectors. Its
  # warnings and errors go to the install log, not unpadded to the screen;
  # the caller's abort says what failed. We do not run partprobe or udevadm
  # settle between partitions: reading back the on-disk table does not depend
  # on udev, and the caller settles once after all partitions and flags are set.
  parted --script "$disk" mkpart "$mkpart_arg" "$fstype" "${start}B" "$((end - 1))B" \
    >>"${OMARCHY_INSTALL_LOG_FILE:-/dev/null}" 2>&1 || return 1

  after_table=$(_read_partition_table "$disk") || return 1
  after=$(printf '%s\n' "$after_table" | awk 'NR > 1 { print $1 }')
  # Exactly one partition more than before, or something else moved.
  (( $(grep -c . <<<"$after") == $(grep -c . <<<"$before") + 1 )) || return 1

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  num=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)
  [[ -n $num ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  actual=$(printf '%s\n' "$after_table" | awk -v n="$num" 'NR > 1 && $1 == n { print $2; exit }')
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  if [[ $label != gpt && -n $name ]]; then
    parted --script "$disk" name "$num" "$name" >>"${OMARCHY_INSTALL_LOG_FILE:-/dev/null}" 2>&1 || true
  fi

  created_parts+=("$num")
  # shellcheck disable=SC2034 # the caller reads it once this returns
  created_partition_number="$num"
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n
  (( ${#created_parts[@]} > 0 )) || return 0
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || true
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
}

# The disks the installer offers, one per line, in the order the disk screen
# lists them. gum highlights the first entry, so that is the default a user
# confirms with Enter: internal disks come first, then removable and USB ones
# (a stick or a KVM's virtual storage left plugged in, an SD card), each group
# in lsblk's order. Leaves out the boot medium's disk ($1), disks with no
# medium, which report size 0 (an empty card reader, a KVM's virtual optical
# drive), and an eMMC's boot and RPMB areas. An SD card in a PCIe reader
# reports RM 0 and TRAN mmc, like the eMMC a laptop boots from; only its MMC
# card type, SD, tells them apart. TRAN is the last column because it is
# empty for some disks (xvd, hd).
install_disk_candidates() {
  local exclude=${1:-} sysfs=${SYSFS_BLOCK:-/sys/block}
  local name type size removable tran external n=0
  lsblk -dbpno NAME,TYPE,SIZE,RM,TRAN |
    while read -r name type size removable tran; do
      n=$((n + 1))
      [[ $type == disk && $size -gt 0 && $name != "$exclude" ]] || continue
      [[ $name =~ ^/dev/(sd|hd|vd|nvme|mmcblk|xv) ]] || continue
      [[ $name =~ ^/dev/mmcblk[0-9]+(boot[0-9]+|rpmb)$ ]] && continue
      external=0
      if [[ $removable == 1 || $tran == usb ]] ||
        [[ $(cat "$sysfs/${name##*/}/device/type" 2>/dev/null) == SD ]]; then
        external=1
      fi
      printf '%s\t%s\t%s\n' "$external" "$n" "$name"
    done |
    sort -k1,1n -k2,2n | cut -f3
}

# The install modes for the disk screen's choice, in order, as the names
# select_installation acts on. Full disk comes first on every disk, as the
# common case; the overwrite confirmation that follows it names the disk
# before anything is erased. $1 is whether the free-space mode is on offer at
# all (UEFI, a partition table and room for Omarchy), $2 whether there is
# another disk to choose.
install_mode_choices() {
  printf '%s\n' full_disk
  if [[ $1 == true ]]; then
    printf '%s\n' free_space
  fi
  if [[ ${2:-true} == true ]]; then
    printf '%s\n' other_disk
  fi
}
