# shellcheck shell=bash
# The root image: verify the build-time btrfs send stream on the boot medium,
# btrfs receive it into the target filesystem, and make it the @ subvolume.
# Ported from the root-image half of the former Python orchestrator.
#
# archinstall-bash (or the configurator, for protected installs) has created
# and mounted the subvolume layout by the time the unpack runs: @ at the
# target, with @home, @log, @pkg and the ESP mounted inside it. `btrfs
# receive` can only create a new subvolume, never fill an existing one, so the
# image is received at the filesystem's top level, snapshotted writable, and
# swapped in for the empty @ while the layout is unmounted; then the layout is
# mounted again exactly as it was. The mount table is replayed from findmnt
# rather than asking the installer to mount a second time, which would also
# unlock LUKS a second time; the mapper stays open throughout.

ROOT_IMAGE_STREAM=/run/archiso/bootmnt/arch/x86_64/omarchy-root.btrfs.zst
# Decompresses the outer whole-stream zstd layer in the receive pipe (the
# per-extent compression inside the stream cannot reach the send framing or
# redundancy that spans extents; the outer pass is ~11% of the stream).
# --long=27 mirrors the compressing side's window: it is within the decoder's
# default acceptance limit, but saying it here keeps the pair visibly in step
# with STREAM_COMPRESS in build-root-image.sh.
ROOT_IMAGE_DECOMPRESS=(zstd -dc --long=27)
ROOT_IMAGE_SUBVOLUME=omarchy-root
BOOT_MEDIUM_MOUNT=/run/archiso/bootmnt

# The boot-time hash of the stream, systemd-supervised so a slow or dying
# medium fails with its own message. The helper collects the verdict: waits
# for the unit if it is still hashing, and starts it if it never ran.
VERIFY_HELPER=/usr/local/bin/omarchy-wait-verify

# Packages the image must carry for the rest of the install to work: Limine
# setup reads the settings package's limine config, useradd copies the skel
# the settings and nvim packages populate, and the target-side setup commands
# come from the runtime package. Checked right after unpacking so a mismatched
# image fails here with a clear message instead of three phases later.
ROOT_IMAGE_REQUIRED_PACKAGES=(limine omarchy-keyring)
# The units that hash what the install reads off the medium.
ROOT_IMAGE_VERIFY_UNIT=omarchy-root-image-verify.service
MIRROR_VERIFY_UNIT=omarchy-mirror-verify.service

root_image_required_packages() {
  printf '%s\n' "${ROOT_IMAGE_REQUIRED_PACKAGES[@]}"
  omarchy_runtime_package
  echo
  omarchy_settings_package
  echo
  omarchy_nvim_package
  echo
}

# The root image replaces the target's @ subvolume, so the configurator JSON
# must put the root on a btrfs @ subvolume, and the image path has no LVM
# support. Checked from the JSON so a layout the image cannot land on fails
# before the installer creates it.
verify_root_image_layout() {
  local lvm ok
  lvm=$(user_configuration_get '.disk_config.lvm_config // empty')
  [[ -z $lvm ]] || fail 'root image install does not support LVM layouts'

  ok=$(user_configuration_get '[.disk_config.device_modifications // [] | .[] | .partitions // [] | .[] | select(.fs_type == "btrfs") | .btrfs // [] | .[] | select(.mountpoint == "/" and (.name == "@" or .name == "/@"))] | length')
  [[ ${ok:-0} -gt 0 ]] ||
    fail 'root image install needs the target root on a btrfs @ subvolume; disk_config mounts / from no such subvolume'
}

# The stream is present and hashes to what the build recorded. A truncated or
# corrupt copy (a badly flashed USB is the common case) would also trip btrfs
# receive's per-command checksums, but only after the disk is formatted.
#
# The helper is the single source of truth: it collects the
# boot-time hasher's verdict, waiting for the unit if it is still running and
# starting it if it never did, and logs the boot medium and its I/O
# scheduler. The free-space configurator gate runs the same helper before it
# partitions, so both disk-touching paths clear the same check; whoever gets
# there first pays the wait. The hasher's read also leaves as much of the
# stream as fits in the page cache for the unpack that follows.
# Run the shared waiter and surface what it says: its stdout is progress and
# context worth logging line by line, its stderr is the verdict, whose first
# line headlines the install dashboard.
run_verify_helper() {
  local out_file="$CTX_STATE_DIR/.verify.out" err_file="$CTX_STATE_DIR/.verify.err" rc=0 line
  "$VERIFY_HELPER" "$@" >"$out_file" 2>"$err_file" || rc=$?
  while IFS= read -r line; do
    [[ -n ${line// /} ]] && info "› $line"
  done <"$out_file"

  if ((rc != 0)); then
    local err
    err=$(<"$err_file")
    fail "${err:-$VERIFY_HELPER $1 failed with status $rc}"
  fi
  rm -f "$out_file" "$err_file"
}

verify_root_image_stream() {
  # The earliest the installer can know the medium is gone -- checked here in
  # the pre-flight gate, before anything formats the disk, not at unpack
  # time when the disk is already wiped. A missing stream would also fail
  # the verify unit's condition below, but with a verdict that cannot name
  # the one cause a user can act on: the archiso hook unmounts the boot
  # medium after copying the airootfs to RAM (copytoram). The boot entries
  # pin copytoram=n, so that only happens when someone edits the kernel
  # command line. First the mount, then the stream on it.
  if ! mountpoint -q "$BOOT_MEDIUM_MOUNT"; then
    fail "boot medium is not mounted at $BOOT_MEDIUM_MOUNT: the live system was copied to RAM (copytoram) and the medium released; boot with copytoram=n"
  fi
  if [[ ! -f $ROOT_IMAGE_STREAM ]]; then
    fail "root image stream missing: $ROOT_IMAGE_STREAM"
  fi
  publish_verify_progress
  run_verify_helper "$ROOT_IMAGE_VERIFY_UNIT" "the root image" "$ROOT_IMAGE_STREAM"
}

# Wait for the mirror to be proven before letting the install proceed, because
# the phase after this one formats the disk. Everything the install could read
# is covered: not just the kernel and microcode this machine will pull, but the
# dependencies pacman resolves later and the hardware packages chosen after the
# image lands -- any of which failing mid-pacstrap would leave someone with no
# system at all.
#
# `systemctl start` on a oneshot returns immediately if it already finished and
# blocks if it is still running, so this waits only for what the boot-time head
# start did not cover. On a fast medium there is nothing left to wait for; on a
# slow one this is where that time is spent, which is the right place for it.
verify_offline_mirror() {
  run_verify_helper "$MIRROR_VERIFY_UNIT" "the offline mirror"
}

# While the boot-time hasher is still reading the stream, mirror its read
# position into phase_progress so the dashboard bar tracks the actual hash
# instead of the phase's time-driven band. Best effort throughout: the helper
# is the authority on the verdict, and any hiccup here (unit already done,
# hasher between opens, /proc gone) just skips a sample.
publish_verify_progress() {
  local total pos
  total=$(stat -c %s "$ROOT_IMAGE_STREAM" 2>/dev/null) || return 0
  ((total > 0)) || return 0
  while [[ $(verify_unit_property ActiveState) == activating ]]; do
    pos=$(hasher_read_pos)
    [[ -n $pos ]] && phases_write_progress "$(awk -v p="$pos" -v t="$total" 'BEGIN { printf "%.4f", p / t }')"
    sleep 0.5
  done
  return 0
}

verify_unit_property() {
  systemctl show "$ROOT_IMAGE_VERIFY_UNIT" -p "$1" --value 2>/dev/null || true
}

# Byte offset of the hasher's open fd on the stream: the unit's MainPID is
# the stall watchdog and sha256sum its direct child, so both are candidates,
# and fdinfo's pos is how far the holder has read.
hasher_read_pos() {
  local mainpid pid pids fd target pos
  mainpid=$(verify_unit_property MainPID)
  [[ $mainpid =~ ^[0-9]+$ && $mainpid != 0 ]] || return 0
  pids=("$mainpid" $(cat "/proc/$mainpid/task"/*/children 2>/dev/null))
  for pid in "${pids[@]}"; do
    for fd in "/proc/$pid/fd"/*; do
      target=$(readlink -f "$fd" 2>/dev/null) || continue
      [[ $target == "$ROOT_IMAGE_STREAM" ]] || continue
      # || true: the hasher can exit between the MainPID read and this one,
      # and an awk that cannot open the file exits 2, which set -eE would turn
      # into a failed phase.
      pos=$(awk '/^pos:/ { print $2; exit }' "/proc/$pid/fdinfo/${fd##*/}" 2>/dev/null || true)
      [[ -n $pos ]] && { printf '%s' "$pos"; return 0; }
    done
  done
  return 0
}

# The mount table under the target, checked for what the image swap needs:
# the target itself mounted, btrfs, on the @ subvolume. Sets RIMG_MOUNTS_JSON
# (every mount at or below the target, parents before children) and
# RIMG_DEVICE (the device backing the root).
root_image_target_mounts() {
  local json
  json=$(findmnt -R -J -o TARGET,SOURCE,FSTYPE,OPTIONS "$CTX_TARGET" 2>/dev/null) ||
    fail "$CTX_TARGET is not a mountpoint"
  RIMG_MOUNTS_JSON=$(jq -c '[.filesystems[] | recurse(.children[]?) | {target, source, fstype, options}]' <<<"$json")

  local root_target root_fstype root_options
  { read -r root_target; read -r root_fstype; read -r root_options; read -r RIMG_DEVICE; } < <(
    jq -r '.[0] | (.target // ""), (.fstype // ""), (.options // ""), (.source // "")' <<<"$RIMG_MOUNTS_JSON")
  [[ $root_target == "$CTX_TARGET" ]] || fail "$CTX_TARGET is not a mountpoint"
  [[ $root_fstype == btrfs ]] || fail "root image install needs a btrfs target root, got ${root_fstype:-unknown}"
  list_contains "${root_options//,/ }" 'subvol=/@' || list_contains "${root_options//,/ }" 'subvol=@' ||
    fail "root image install needs the target root on the @ subvolume, got $root_options"

  RIMG_DEVICE=${RIMG_DEVICE%%\[*}
  [[ -n $RIMG_DEVICE ]] || fail "could not determine the btrfs device backing $CTX_TARGET"
}

# Mount options for the replay: subvolid refers to the subvolume replaced
# here; subvol= names it.
remount_option_string() {
  local opt opts out=()
  IFS=, read -ra opts <<<"$1"
  for opt in "${opts[@]}"; do
    [[ $opt == subvolid=* ]] || out+=("$opt")
  done
  local IFS=,
  printf '%s' "${out[*]}"
}

replay_target_mounts() {
  local target source fstype options
  while IFS=$'\t' read -r target source fstype options; do
    source=${source%%\[*}
    mkdir -p "$target"
    mount -t "$fstype" -o "$(remount_option_string "$options")" "$source" "$target"
  done < <(jq -r '.[] | [.target, (.source // ""), .fstype, (.options // "")] | @tsv' <<<"$RIMG_MOUNTS_JSON")
}

# umount -R with a few retries: the dashboard polls the target's pacman db
# from another process, and a poll landing mid-unmount is EBUSY.
umount_tree() {
  local root=$1 attempts=${2:-20} attempt err
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    err=$(umount -R "$root" 2>&1) && return 0
    ((attempt == attempts)) && fail "could not unmount $root: $err"
    sleep 0.25
  done
}

install_root_image() {
  # The stream's existence and checksum were proven by the pre-flight gate
  # (verify_root_image_stream), before the disk was touched.
  local stream=$ROOT_IMAGE_STREAM target=$CTX_TARGET
  root_image_target_mounts

  local top="$CTX_STATE_DIR/image-top"
  mkdir -p "$top"
  # A transient mount unit (the device is only known at run time, so no
  # static unit file can name it): PartOf= the install target means a
  # mid-phase death unmounts it with the group teardown, with no per-process
  # trap bookkeeping.
  systemd-mount --quiet -o subvolid=5 --property=PartOf=omarchy-install.target \
    "$RIMG_DEVICE" "$top" || fail "could not mount the target filesystem's top level at $top"

  local received="$top/$ROOT_IMAGE_SUBVOLUME"
  if [[ -e $received ]]; then
    btrfs subvolume delete "$received" >/dev/null 2>&1 || fail "could not delete a stale $received"
  fi

  local size_mib
  size_mib=$((($(stat -c %s "$stream")) >> 20))
  info "› unpacking root image (${size_mib} MiB stream from $stream)"
  receive_root_image "$top" "$stream"

  local staged="$top/@.image"
  if [[ -e $staged ]]; then
    btrfs subvolume delete "$staged" >/dev/null 2>&1 || fail "could not delete a stale $staged"
  fi
  btrfs subvolume snapshot "$received" "$staged" >/dev/null || fail "could not snapshot the received image"
  btrfs subvolume delete "$received" >/dev/null || fail "could not delete the received snapshot"

  # The image's pacman.log ends up under the @log mount; carry it over so the
  # installed system's log starts with the packages it was built from.
  if [[ -f $staged/var/log/pacman.log && -d $top/@log ]]; then
    cp -p "$staged/var/log/pacman.log" "$top/@log/pacman.log"
  fi

  info '› making the image the root subvolume'
  umount_tree "$target"
  # The layout is replayed whatever happens to the swap, so a failure leaves
  # a diagnosable (and releasable) mounted target rather than a bare one.
  local swap_rc=0
  { btrfs subvolume delete "$top/@" >/dev/null && mv "$staged" "$top/@"; } || swap_rc=$?
  replay_target_mounts
  ((swap_rc == 0)) || fail "could not swap the root image in for @"

  systemd-umount --quiet "$top" >/dev/null 2>&1 || true

  local pkg missing=()
  while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    target_has_package "$target" "$pkg" || missing+=("$pkg")
  done < <(root_image_required_packages)
  ((${#missing[@]} == 0)) || fail "root image lacks required packages: $(
    IFS=', '
    echo "${missing[*]}"
  )"

  # Per-machine identity the image deliberately ships without.
  systemd-machine-id-setup --root="$target" >/dev/null 2>&1 || fail "could not set the target's machine id"
}

# Pipe the stream through the outer-layer decompressor into btrfs receive,
# publishing progress for the dashboard as a fraction of stream bytes
# consumed (compressed bytes — the fraction of the medium read, which is what
# the wait is made of) — read straight off the decompressor's stdin fd
# position, the same way the verify phase watches the hasher.
#
# The decompressor owns the read off the medium: a read error there is the
# dying-medium case the verify machinery exists for, and it surfaces in $err
# under its own stage name below, never as mystery receive noise. The pipe
# between the children is what turns a receive that dies early into the
# decompressor's EPIPE, so neither child can be left blocked on the other.
receive_root_image() {
  local top=$1 stream=$2 total pos err="$CTX_STATE_DIR/btrfs-receive.err"
  local pipe="$CTX_STATE_DIR/receive-pipe"
  total=$(stat -c %s "$stream")

  # A named pipe rather than |: each stage is its own child with its own
  # status to wait on (waiting on a background pipeline folds the stages
  # together under pipefail), and the decompressor's pid is in hand for the
  # progress read.
  rm -f "$pipe"
  mkfifo "$pipe" || fail "could not create the receive pipe at $pipe"
  btrfs receive -q "$top" <"$pipe" 2>"$err" &
  local receive_pid=$!
  "${ROOT_IMAGE_DECOMPRESS[@]}" <"$stream" >"$pipe" 2>>"$err" &
  local unzstd_pid=$!
  while kill -0 "$unzstd_pid" 2>/dev/null; do
    # || true is load-bearing: the decompressor can exit between the kill -0
    # above and this read, and awk exits 2 on a file it cannot open. Under
    # set -eE that failure would abort the phase -- killing an install that
    # was seconds from done, over a progress reading nobody needs. An empty
    # pos is already the "no reading this time" case below.
    pos=$(awk '/^pos:/ { print $2; exit }' "/proc/$unzstd_pid/fdinfo/0" 2>/dev/null || true)
    [[ -n $pos && $total -gt 0 ]] &&
      phases_write_progress "$(awk -v p="$pos" -v t="$total" 'BEGIN { printf "%.4f", p / t }')"
    sleep 0.5
  done
  local unzstd_code=0 receive_code=0
  wait "$unzstd_pid" || unzstd_code=$?
  wait "$receive_pid" || receive_code=$?
  rm -f "$pipe"
  if ((receive_code != 0 || unzstd_code != 0)); then
    # Both children share the error file, so the full story is in the detail
    # either way. When both died, which one broke the pipe is not knowable
    # from the exit codes: a corrupt outer layer kills the decompressor and
    # starves the receive, while a receive that dies first EPIPEs the
    # decompressor. The headline names both rather than guessing a culprit,
    # and the detail -- zstd's "premature end", the receive's own complaint
    # -- disambiguates.
    local stage='root image decompression'
    if ((unzstd_code != 0 && receive_code != 0)); then
      stage='root image decompression and btrfs receive both'
    elif ((receive_code != 0)); then
      stage='btrfs receive'
    fi
    fail "$stage failed: $(tr -d '\0' <"$err")"
  fi
  phases_write_progress 1
}

# ── per-machine pacman keyring ───────────────────────────────────────────────
# The image ships no /etc/pacman.d/gnupg: its master key would be the same on
# every install, and a shared signing key must never be distributed. On a
# target pacstrapped directly, pacstrap -K initialised the keyring and the
# keyring packages' scriptlets populated it; here those packages come from
# the image, where their scriptlets ran with no keyring to populate. The
# delta pacstrap's -K still ran --init (generating the master key), and
# --init is idempotent, so run it again for installs that pacstrapped
# nothing, then populate from the target's own keyring files. Chroot-free:
# --gpgdir and --populate-from address the target directly, so no API mounts
# are held.
#
# Started after the last pacstrap (each runs its own --init on this dir) and
# joined by create_factory_snapshot: nothing in between reads the keyring
# (the offline repo is SigLevel = Never) or writes it, and the snapshot must
# not capture it half-written. A unit rather than a plain child process:
# pacman-key leaves a gpg-agent and dirmngr behind, which systemd kills with
# the rest of the unit's cgroup the moment pacman-key exits (sockets under
# the target's gnupg dir would otherwise block the unmount); the dashboard's
# process-group kill does not reach it, while `systemctl stop` still does
# (the group stop of omarchy-install.target, which it is PartOf=); and its output is in the journal whatever
# happens to the orchestrator.
#
# The unit is shipped, omarchy-target-keyring.service, and reads the target
# path from the install context env files (the defaults beside this script,
# overlaid by the runtime context ctx_from_env writes) -- the commands live
# in the unit file with the other install-medium units. systemd is also the
# whole process tracker: start --no-block hands the work over, and with the
# unit's RemainAfterExit=yes its state alone answers the join -- inactive
# never ran, activating still running, active succeeded, failed failed --
# the same technique the verify units use. Nothing is tracked here.

TARGET_KEYRING_UNIT=omarchy-target-keyring.service

start_target_keyring_init() {
  info '› initializing per-machine pacman keyring (background unit)'
  systemctl start --no-block "$TARGET_KEYRING_UNIT" ||
    fail "could not start $TARGET_KEYRING_UNIT"
}

# Wait out the keyring unit and raise its failure; a unit that never ran is
# the no-op. With --no-raise the install's own error wins (the exit path).
# The poll is bounded by the unit's TimeoutStartSec; phases of install
# separate it from the start, so the job is long past enqueued by the time
# anyone joins.
join_target_keyring_init() {
  local raise=true
  [[ ${1:-} == --no-raise ]] && raise=false
  local state
  while state=$(systemctl show -p ActiveState --value "$TARGET_KEYRING_UNIT" 2>/dev/null) &&
        [[ $state == activating ]]; do
    sleep 0.5
  done
  if [[ $state == failed && $raise == true ]]; then
    # pacman-key's own words are in the journal; the unit has the how.
    fail "per-machine pacman keyring init failed ($(systemctl show -p Result --value "$TARGET_KEYRING_UNIT" 2>/dev/null)): $(journalctl --no-pager -o cat -b -u "$TARGET_KEYRING_UNIT" 2>/dev/null | tail -n 5 | tr '\n' ' ')"
  fi
  return 0
}

