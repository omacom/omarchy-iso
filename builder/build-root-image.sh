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

# Compile the default locale into the image. archinstall's set_locale
# uncomments the chosen locale and runs locale-gen on the target, which
# rebuilds the whole locale archive: 0.77 s for en_US.UTF-8 in a traced
# install. With the archive already holding it, the orchestrator skips that
# run (luks_tuning._run_command); any other locale still compiles as before.
if grep -q '^#en_US.UTF-8 UTF-8' "$root/etc/locale.gen"; then
  sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$root/etc/locale.gen"
  arch-chroot "$root" locale-gen >/dev/null && echo "en_US.UTF-8 compiled into the image's locale archive"
fi

# The runtime's install log helper forks `date` twice per script it runs
# (131 forks in a traced install, about 0.5 s). bash formats the same
# timestamp itself. Same output, no fork; patched here until the runtime
# package carries the change.
logging_sh="$root/usr/share/omarchy/install/helpers/logging.sh"
if [[ -f $logging_sh ]] && grep -q "date '+%Y-%m-%d %H:%M:%S'" "$logging_sh"; then
  sed -i \
    -e 's/\$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')/$(printf "%(%Y-%m-%d %H:%M:%S)T" -1)/g' \
    -e 's/\$(date +%s)/$EPOCHSECONDS/g' \
    "$logging_sh"
  bash -n "$logging_sh" && echo "logging.sh: timestamps without forking date"
fi

# Package names no repository offers any more: follow the known renames in the
# image's install scripts, refuse to ship one that still asks for a dropped name.
bash "$(dirname -- "${BASH_SOURCE[0]}")/follow-renamed-packages.sh" "$root/usr/share/omarchy/install" \
  "${OMARCHY_RENAMED_PACKAGES:-}" "${OMARCHY_UNRESOLVED_PACKAGES:-}"

sync

# Build the UKI here, once, so the installer copies it to the ESP and skips
# the ~4 s of mkinitcpio, ukify and limine-entry-tool on the target.
#
# Its cmdline is generic, with no root= and no resume=: the initramfs has the
# systemd hook, so systemd-gpt-auto-generator finds the root by its partition
# type GUID.
#
# /boot/EFI/Linux inside the image is shadowed by the ESP mount at install
# time, so the UKI is kept in /var/lib/omarchy-iso, where nothing mounts over
# it.
mkdir -p "$root/etc/kernel" "$root/etc/mkinitcpio.d" "$root/var/lib/omarchy-iso"
# systemd.tty.term.console=dumb: see CONSOLE_NO_ANSI_QUERY in the orchestrator
# (systemd's console size query hangs 1 boot in 10 with Plymouth on the VT).
# This embedded cmdline is what boots under Secure Boot, where Limine's entry
# options are ignored.
cat >"$root/etc/kernel/cmdline" <<'CMDLINE'
zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs initramfs_async=0 quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0 systemd.tty.term.console=dumb
CMDLINE

# The preset names the kernel version explicitly: mkinitcpio treats a glob in
# ALL_kver as a literal path. It sets no ALL_microcode, which is deprecated;
# the microcode hook in mkinitcpio.conf adds the microcode.
image_kver=$(ls -1 "$root/usr/lib/modules/" | grep -E '^[0-9]+\.' | head -1)
if [[ -z $image_kver ]]; then
  echo "WARNING: no kernel version found under /usr/lib/modules/; skipping the UKI pre-build"
else
  # The kernel package this image carries: linux-omarchy since upstream made it
  # the default, stock linux before. The installer names the UKI
  # and its Limine entry after it.
  image_kernel=$(<"$root/usr/lib/modules/${image_kver}/pkgbase")
  echo "$image_kernel" >"$root/var/lib/omarchy-iso/prebuilt-uki.kernel"
  cat >"$root/etc/mkinitcpio.d/${image_kernel}.preset" <<PRESET
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/usr/lib/modules/${image_kver}/vmlinuz"
PRESETS=('default')
default_uki="/var/lib/omarchy-iso/prebuilt-uki.efi"
default_options="-S autodetect"
PRESET

  # The pre-built UKI's own config. Naming a config with -c makes mkinitcpio
  # skip /etc/mkinitcpio.conf.d, which is where omarchy_hooks.conf sets the
  # busybox hook list (udev ... encrypt): that list needs cryptdevice= and
  # root= on the cmdline, which a build-time UKI cannot know. The systemd
  # hook set needs neither: systemd-gpt-auto-generator finds the root
  # partition by its GPT type, and if it is LUKS, sd-encrypt unlocks it at a
  # passphrase prompt (plymouth draws it). One UKI for plain and encrypted
  # installs; the first kernel update rebuilds it from the drop-ins as usual.
  # Persistent dm-crypt flags (discards, no read workqueue) come from the LUKS2
  # header, written by the installer at open time, not from the cmdline.
  # limine-snapper-sync boots read-only snapshots through its busybox
  # `btrfs-overlayfs` hook (an overlay with a tmpfs upper over the snapshot).
  # The systemd initramfs has no equivalent, so a snapshot booted with the
  # pre-built UKI would come up read-only. This is the same
  # logic as a oneshot in the initrd: after sysroot.mount, before
  # initrd-root-fs.target, mount an overlay on top of /sysroot when it is a
  # read-only btrfs snapshot subvolume. Installed as an ordinary mkinitcpio
  # hook so a systemd-hook rebuild would keep it too.
  install -d "$root/usr/lib/initcpio/install" "$root/usr/lib/omarchy"
  cat >"$root/usr/lib/omarchy/snapshot-overlay" <<'SCRIPT'
#!/bin/bash
# Mount an overlay over /sysroot when it is a read-only btrfs snapshot, so a
# snapshot chosen from the boot menu is writable for the session (changes go
# to a tmpfs and vanish on reboot), as limine-snapper-sync's busybox hook does.
root=/sysroot
[[ $(findmnt -no FSTYPE "$root" 2>/dev/null) == btrfs ]] || exit 0
case $(findmnt -no SOURCE "$root" 2>/dev/null) in */snapshot*) ;; *) exit 0 ;; esac
[[ $(btrfs property get -t subvol "$root" ro 2>/dev/null) == "ro=true" ]] || exit 0
echo "[snapshot-overlay] $root is a read-only btrfs snapshot; mounting an overlay"
ram=/run/omarchy-snapshot-overlay
mkdir -p "$ram" && mount -t tmpfs cowspace "$ram" && mkdir -p "$ram/upper" "$ram/work" || exit 0
mount -t overlay overlay -o "lowerdir=$root,upperdir=$ram/upper,workdir=$ram/work" "$root"   && echo "[snapshot-overlay] overlay mounted on $root"
exit 0
SCRIPT
  chmod 0755 "$root/usr/lib/omarchy/snapshot-overlay"
  cat >"$root/usr/lib/initcpio/install/sd-btrfs-overlayfs" <<'INSTALL'
#!/usr/bin/env bash
build() {
    add_module btrfs
    add_module overlay
    add_binary btrfs
    add_binary findmnt
    add_binary mount
    add_binary mkdir
    add_binary bash
    # add_systemd_unit also pulls in the unit's ExecStart binary.
    add_systemd_unit omarchy-snapshot-overlay.service
    add_symlink /usr/lib/systemd/system/initrd-root-fs.target.wants/omarchy-snapshot-overlay.service \
        ../omarchy-snapshot-overlay.service
}
help() {
    cat <<HELPEOF
Systemd-initramfs twin of limine-snapper-sync's btrfs-overlayfs hook: boots a
read-only btrfs snapshot with a tmpfs overlay so it is writable for the session.
HELPEOF
}
INSTALL
  chmod 0755 "$root/usr/lib/initcpio/install/sd-btrfs-overlayfs"
  install -d "$root/usr/lib/systemd/system"
  cat >"$root/usr/lib/systemd/system/omarchy-snapshot-overlay.service" <<'UNIT'
[Unit]
Description=Overlay for a read-only btrfs snapshot root (initrd)
DefaultDependencies=no
ConditionPathExists=/etc/initrd-release
After=sysroot.mount
Before=initrd-root-fs.target initrd-parse-etc.service
Requires=sysroot.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/omarchy/snapshot-overlay
UNIT

  cat >"$root/etc/mkinitcpio-prebuilt-uki.conf" <<'CONF'
MODULES=(thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs)
COMPRESSION="zstd"
CONF

  # Room for the installer to write the real cmdline into the UKI in place
  # (orchestrator/uki_cmdline.py): one placeholder parameter pads .cmdline to
  # 1800 bytes, under the kernel's 2048. A dotted name is a module parameter
  # to the kernel, so until it is overwritten it is ignored without a warning.
  prebuilt_cmdline=$(tr -s '\n ' ' ' <"$root/etc/kernel/cmdline")
  prebuilt_cmdline="${prebuilt_cmdline% } omarchy.cmdline_room="
  printf '%s%s\n' "$prebuilt_cmdline" "$(printf '%*s' $((1800 - ${#prebuilt_cmdline})) '' | tr ' ' 0)" \
    >"$root/etc/kernel/cmdline.prebuilt-uki"

  echo "Pre-building the UKI in the image (kver=$image_kver, generic cmdline, systemd and sd-encrypt hooks, no autodetect)"
  # mkinitcpio is called directly: the preset flow (-P) runs Limine's install
  # hooks, which fail without a mounted ESP.
  if arch-chroot "$root" mkinitcpio \
       -k "/usr/lib/modules/${image_kver}/vmlinuz" \
       -c /etc/mkinitcpio-prebuilt-uki.conf \
       --cmdline /etc/kernel/cmdline.prebuilt-uki \
       -U /var/lib/omarchy-iso/prebuilt-uki.efi \
       -S autodetect 2>&1 | tail -25 ; then
    if [[ -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi" ]]; then
      echo "Pre-built UKI: $(du -h "$root/var/lib/omarchy-iso/prebuilt-uki.efi" | cut -f1)"
    else
      echo "WARNING: mkinitcpio ran but left no UKI; the installer will build one"
    fi
  else
    echo "WARNING: mkinitcpio failed; the installer will build the UKI"
    # Clean up any partial output that would upset btrfs shrink downstream.
    rm -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi"
  fi
  # Only this build uses these; the installed system has no use for them.
  rm -f "$root/etc/mkinitcpio-prebuilt-uki.conf" "$root/etc/kernel/cmdline.prebuilt-uki"
fi

# Emit the filesystem image itself, not a send stream. The installer writes
# it straight onto the target partition, gives the filesystem a new fsid and
# grows it to fill the partition: no btrfs receive, and about 14 s becomes
# about 3 s on a Gen4 NVMe.
#
# Shrink the filesystem and truncate the backing file first: xorriso stores a
# file at its apparent size, so a sparse 24 GiB backing file would overflow
# the medium even with 5 GiB in use.
sync
# Size it from the bytes actually in use, plus slack. `btrfs inspect-internal
# min-dev-size` is unreliable (Debian bug #921038: off by gigabytes in both
# directions). Too large is harmless, because the installer grows the
# filesystem anyway; too small corrupts it.
used_bytes=$(btrfs filesystem usage --raw "$mnt" | awk '/^\s+Used:/ {print $2; exit}')
# 2 GiB of slack: shrinking relocates block groups and fails with ENOSPC when
# the new size is too tight.
shrink_mb=$(( (used_bytes / 1048576) + 2048 ))
echo "Shrinking image btrfs to ${shrink_mb}M (used $((used_bytes / 1048576))M + 2048M slack)"
# If the shrink fails, ship the image at its current size.
if ! btrfs filesystem resize "${shrink_mb}M" "$mnt"; then
  echo "WARNING: btrfs shrink to ${shrink_mb}M failed; keeping the current size"
  shrink_mb=$(( ${OMARCHY_IMAGE_SIZE:-24G} ))
  shrink_mb=$(( ${shrink_mb%G} * 1024 ))
fi
sync
umount "$mnt"
losetup -d "$loop"
truncate -s "${shrink_mb}M" "$backing"
# build-iso.sh passes the final file name, omarchy-root.img.zst.
zst_output="$output"
[[ $zst_output == *.zst ]] || zst_output="${zst_output}.zst"

# Compress the image for the ISO. zstd collapses the unused space; the data
# is already compressed inside btrfs and shrinks little. Measured: 6.3 GB
# becomes 3.8 GB at zstd -3, for about 1 s more at install time, because the
# decompression runs alongside the write.
echo "Compressing the root image with zstd -3"
zstd -3 -q --stdout "$backing" >"$zst_output"
echo "Root image raw.zst: $(du -h "$zst_output" | cut -f1) at $zst_output (from ${shrink_mb}M apparent input)"
