# shellcheck shell=bash
# Disk discovery, partition-table probing, mode-selection, and udev settle
# helpers shared by the ISO configurator and its unit tests.
#
# Partition creation, formatting, mounting, and rollback live in
# orchestrator/free_space.py.

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
settle_disk_devices() {
  local disk="${1:-}" timeout="${2:-}"
  local settle_args=(settle)
  if [[ -n $timeout ]]; then
    settle_args+=("--timeout=$timeout")
  fi

  if [[ -z $disk ]] || ! _is_block_device "$disk"; then
    udevadm "${settle_args[@]}" 2>/dev/null || true
    return 0
  fi

  udevadm "${settle_args[@]}" 2>/dev/null &
  local settle_pid=$!
  local ticks probe_fd

  # Backoff schedule (60 ms, 120 ms, 250 ms, 250 ms, 250 ms) lets healthy
  # drains finish with zero extra events, while breaking a 200 ms + 1 s
  # EVENT_LOCKED timer stall once no synth/worker holds the whole-disk lock.
  for ticks in 6 12 25 25 25; do
    if _wait_pid_ticks "$settle_pid" "$ticks"; then
      break
    fi
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
