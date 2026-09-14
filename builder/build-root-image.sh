#!/bin/bash
#
# Build the root filesystem image the installer unpacks instead of pacstrapping
# every package on the target machine.
#
# The target install is the same ~940 packages for everyone; only the kernel,
# CPU microcode, audio firmware and Tailscale vary per machine. So pacstrap the
# invariant set once here, at build time, into a btrfs subvolume compressed at
# a high zstd level (see IMAGE_COMPRESS below — higher than the installer's own
# compress=zstd, since the level only costs build time), and ship it as a
# `btrfs send --compressed-data` stream. At install time `btrfs receive` writes
# the compressed extents straight to disk (no decompress/recompress), which
# measured at roughly half the time of extracting the same packages with pacman,
# independent of CPU count; the per-machine delta is a small pacstrap after.
#
# The stream itself then gets an outer zstd layer (STREAM_COMPRESS below). The
# per-extent compression above cannot see past a 128 KiB extent, so the send
# stream still carries its protocol framing uncompressed plus redundancy that
# only exists across extents; one whole-stream pass reclaims ~11% (measured on
# a 3.75 GB stream — and the level barely matters, the long-range window does).
# The installer decompresses it in the receive pipe, where zstd -d is orders of
# magnitude faster than any install medium; the extents inside still land on
# disk as they are.
#
# Usage: build-root-image.sh <pacman.conf> <output-stream> <package>...
#
#   pacman.conf     Config whose repositories resolve every package; its
#                   CacheDir must hold the package files so nothing is copied.
#   output-stream   Where to write the send stream.
#   package...      Packages to pacstrap into the image.
#
# Environment:
#   OMARCHY_IMAGE_LOCALDB_COPY  Directory to copy the image's pacman local db
#                               into, so the caller can resolve the per-machine
#                               delta against what the image already holds.
#   OMARCHY_IMAGE_SIZE          Sparse backing file size (default 24G). Only the
#                               written extents cost anything.
#
# Needs a privileged environment: loop devices and a btrfs mount.

set -euo pipefail

pacman_conf="${1:-}"
output="${2:-}"
shift 2 || true
packages=("$@")

if [[ -z $pacman_conf || -z $output || ${#packages[@]} -eq 0 ]]; then
  echo "Usage: build-root-image.sh <pacman.conf> <output-stream> <package>..." >&2
  exit 1
fi
if [[ ! -r $pacman_conf ]]; then
  echo "ERROR: pacman config not readable: $pacman_conf" >&2
  exit 1
fi

# Forced zstd at a higher level than the installer's own compress=zstd (level
# 3): btrfs's incompressibility heuristic declines a lot of data in this tree
# that zstd handles fine, and the level only costs build time. btrfs receive
# stores the extents as they arrive, so neither choice affects install speed;
# the installed system writes new data at its own mount option either way.
IMAGE_COMPRESS="compress-force=zstd:15"
# Outer layer over the whole send stream. Level 15 and the 128 MiB long-range
# window are each worth a few hundred MB/-tens of MB respectively over the
# defaults; beyond either lies ~0.3% for minutes of build time (level 19+) or
# a stream a stock `zstd -d` refuses (--long>27 exceeds the decoder's default
# window limit). -T0 is a pure win: ~25 s on a many-core builder, same bytes.
STREAM_COMPRESS=(zstd -q -15 --long=27 -T0)
# Name of the subvolume inside the stream. The orchestrator looks for this name
# after `btrfs receive` (phases_impl.ROOT_IMAGE_SUBVOLUME).
IMAGE_SUBVOLUME="omarchy-root"

# Boot-image pacman hooks that must not run while the image is built: there is
# no kernel in the image and no ESP to deploy to. pacstrap reads hooks from the
# building system's /etc/pacman.d/hooks (pacman.conf(5): HookDir is absolute,
# the target root is not prepended), so mask them here, the same way the
# orchestrator masks the live ISO's around its pacstrap. Keep in step with
# DEFERRED_BOOT_HOOKS in
# configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py.
deferred_boot_hooks=(
  60-mkinitcpio-remove.hook
  60-limine-mkinitcpio-remove-pre.hook
  80-limine-efi-deploy.hook
  90-limine-mkinitcpio-remove-post.hook
  90-mkinitcpio-install.hook
)

work=$(mktemp -d /tmp/omarchy-root-image.XXXXXX)
backing="$work/image.btrfs"
mnt="$work/mnt"
loop=""
masked_hooks=()

# Anything that touches a keyring under the image (pacman-key in a scriptlet,
# say) starts a gpg-agent for that homedir and leaves it running; until it is
# gone the image cannot be unmounted. Nothing should, as no keyring exists in
# the image, but kill whatever did.
stop_image_gpg_agents() {
  gpgconf --homedir "$mnt/$IMAGE_SUBVOLUME/etc/pacman.d/gnupg" --kill all 2>/dev/null || true
  pkill -f "$mnt/$IMAGE_SUBVOLUME/etc/pacman.d/gnupg" 2>/dev/null || true
}

cleanup() {
  local status=$?
  set +e
  for hook in "${masked_hooks[@]}"; do
    rm -f "/etc/pacman.d/hooks/$hook"
    if [[ -e "/etc/pacman.d/hooks/$hook.omarchy-backup" ]]; then
      mv -f "/etc/pacman.d/hooks/$hook.omarchy-backup" "/etc/pacman.d/hooks/$hook"
    fi
  done
  if mountpoint -q "$mnt" 2>/dev/null; then
    stop_image_gpg_agents
    sleep 1
    if ! umount -R "$mnt"; then
      echo "WARNING: $mnt is still mounted; leaving $work in place" >&2
      return $status
    fi
  fi
  if [[ -n $loop ]]; then
    losetup -d "$loop" || true
  fi
  rm -rf "$work"
  return $status
}
trap cleanup EXIT

mkdir -p /etc/pacman.d/hooks
for hook in "${deferred_boot_hooks[@]}"; do
  path="/etc/pacman.d/hooks/$hook"
  # Already masked: an earlier run died before its cleanup. Moving the mask
  # over that run's backup would lose the real hook for good, so leave both
  # for it to be restored by hand (the orchestrator's _is_devnull_symlink
  # makes the same call).
  if [[ -L $path && $(readlink "$path") == /dev/null ]]; then
    echo "WARNING: $path is already masked; leaving it and any backup alone" >&2
    continue
  fi
  if [[ -e $path || -L $path ]]; then
    mv -f "$path" "$path.omarchy-backup"
  fi
  ln -s /dev/null "$path"
  masked_hooks+=("$hook")
done

echo "Building root image with ${#packages[@]} packages"
truncate -s "${OMARCHY_IMAGE_SIZE:-24G}" "$backing"
# Docker fills the container's /dev once, at start. A loop device the kernel
# creates afterwards (loop-control hands one out on demand, loading the module
# on a host that had none) exists on the host but has no node in here, so make
# the nodes ourselves when they are missing.
[[ -e /dev/loop-control ]] || mknod /dev/loop-control c 10 237
# losetup reports a device whose node is missing as "/dev/loopN (lost)".
loop=$(losetup --find | awk '{ print $1 }')
[[ $loop == /dev/loop[0-9]* ]] || { echo "ERROR: no free loop device: $loop" >&2; exit 1; }
[[ -b $loop ]] || mknod "$loop" b 7 "${loop#/dev/loop}"
losetup "$loop" "$backing"
mkfs.btrfs -q -L omarchy-root-image "$loop"
mkdir -p "$mnt"
mount -o "$IMAGE_COMPRESS" "$loop" "$mnt"
btrfs subvolume create "$mnt/$IMAGE_SUBVOLUME" >/dev/null
root="$mnt/$IMAGE_SUBVOLUME"

# -c: packages come straight from the config's CacheDir (the offline mirror),
#     so nothing is copied into the image's own cache first.
# -G: no pacman keyring in the image, neither the builder's copied in nor one
#     initialised here (-K): its master key would be the same on every
#     install, and a shared signing key must never be distributed. The
#     installer initialises and populates a per-machine keyring on the target
#     (phases_impl._init_target_keyring), as pacstrap -K plus the keyring
#     packages' scriptlets did when the target was pacstrapped directly.
# -M: the builder's mirrorlist means nothing to an installed system; the
#     installer writes the target's own.
pacstrap -C "$pacman_conf" -c -G -M "$root" "${packages[@]}"
stop_image_gpg_agents
# The keyring packages' scriptlets only populate an existing keyring, so with
# -G they have nothing to do; remove whatever a scriptlet may have seeded
# anyway rather than trust that.
rm -rf "$root/etc/pacman.d/gnupg"

# Per-machine identity is the installer's job, never the image's: it runs
# systemd-machine-id-setup on the target after unpacking. Leave the id
# uninitialised rather than shipping one every install would share.
: >"$root/etc/machine-id"

# /var/log is its own subvolume on installed systems and mounts over this
# directory, hiding anything left here. The orchestrator copies the image's
# pacman.log into that subvolume so the installed system keeps its history;
# everything else from the build is noise.
find "$root/var/log" -mindepth 1 ! -name pacman.log -delete

# Nothing downloaded, nothing to keep; and no build-host resolv.conf.
rm -rf "$root/var/cache/pacman/pkg"/* "$root/etc/resolv.conf"

if [[ -n ${OMARCHY_IMAGE_LOCALDB_COPY:-} ]]; then
  rm -rf "$OMARCHY_IMAGE_LOCALDB_COPY"
  mkdir -p "$OMARCHY_IMAGE_LOCALDB_COPY"
  cp -a "$root/var/lib/pacman/local" "$OMARCHY_IMAGE_LOCALDB_COPY/"
fi

installed=$(find "$root/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "Root image holds $installed packages"

sync
btrfs property set -ts "$root" ro true
rm -f "$output"
mkdir -p "$(dirname "$output")"
btrfs send -q --compressed-data "$root" | "${STREAM_COMPRESS[@]}" -o "$output"
echo "Root image stream: $(du -h "$output" | cut -f1) at $output"
