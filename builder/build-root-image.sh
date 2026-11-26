#!/bin/bash
#
# Build the root filesystem image the installer writes instead of pacstrapping
# every package on the target machine.
#
# The target install is the same ~900 packages for everyone; only audio
# firmware, Tailscale and the T2 kernel vary per machine. So pacstrap the
# invariant set once here, at build time, into a btrfs filesystem compressed at
# a high zstd level (see IMAGE_COMPRESS below), shrink it, and pack the
# filesystem image as independent 256 KiB zstd frames with a seek table
# (omarchy-image-write pack). At install time omarchy-image-write decodes the
# frames on every core and writes them straight onto the target partition;
# the installer then gives the filesystem a fresh fsid and grows it to fill
# the partition. The per-machine delta is a small pacstrap after.
#
# Usage: build-root-image.sh <pacman.conf> <output.img.zst> <package>...
#
#   pacman.conf     Config whose repositories resolve every package; its
#                   CacheDir must hold the package files so nothing is copied.
#   output.img.zst  Where to write the packed image.
#   package...      Packages to pacstrap into the image.
#
# Environment:
#   OMARCHY_FAST_COMPRESSION    When 1, build with minimal zstd compression
#                               (btrfs compress-force=zstd:1 directly without staging,
#                               N1x layer zstd -1) for faster test builds.
#   OMARCHY_IMAGE_LOCALDB_COPY  Directory to copy the image's pacman local db
#                               into, so the caller can resolve the per-machine
#                               delta against what the image already holds.
#   OMARCHY_IMAGE_SIZE          Sparse backing file size (default 24G). Only the
#                               written extents cost anything.
#   OMARCHY_IMAGE_SYNC_DBS      The build's online sync directory, whose indexes
#                               the image ships (ship-sync-databases.sh).
#
# Needs a privileged environment: loop devices and a btrfs mount.

set -euo pipefail

# The pre-built UKI boots every install that keeps the defaults, so it has to
# fit where the boot loader can place it (see the kms note at its config).
# 128 MiB, the live initramfs's limit, is well over the 87 MiB it measures
# without kms.
prebuilt_uki_size_ok() {
  local bytes limit=$((128 * 1024 * 1024))
  bytes=$(stat -c %s "$1")
  if ((bytes > limit)); then
    echo "ERROR: the pre-built UKI is $bytes bytes, over the $limit limit (omacom/omarchy#5980)" >&2
    return 1
  fi
}

# The N1x UKI boots a laptop whose kernel alone is 61 MiB (arm64 kernels are
# not compressed) and whose NVIDIA firmware is most of 100 MiB more. The N1x
# boots such a UKI on every installed system, so it gets its own ceiling; the
# 128 MiB one is for the x86 laptops of omacom/omarchy#5980.
n1x_prebuilt_uki_size_ok() {
  local bytes limit=$((256 * 1024 * 1024))
  bytes=$(stat -c %s "$1")
  if ((bytes > limit)); then
    echo "ERROR: the N1x pre-built UKI is $bytes bytes, over the $limit limit" >&2
    return 1
  fi
}

# The MODULES+= lines n1x.sh writes on an N1x whose GPU drives the panel,
# normalized the way the installer reads them (_initramfs_module_lines).
n1x_module_lines() {
  grep -hE '^\s*MODULES\s*\+?=' "$1" | sed -E 's/\s+/ /g; s/^ //; s/ $//' | sort -u
}

# The pre-built initramfs becomes the boot image of every systemd-boot install
# that keeps the defaults, with the kernel next to it on the ESP, so it gets
# the UKI's ceiling. Without kms it measures about 50 MiB.
prebuilt_initramfs_size_ok() {
  local bytes limit=$((128 * 1024 * 1024))
  bytes=$(stat -c %s "$1")
  if ((bytes > limit)); then
    echo "ERROR: the pre-built initramfs is $bytes bytes, over the $limit limit" >&2
    return 1
  fi
}

# What mkinitcpio builds an initramfs from besides the packages: its
# configuration, the hooks a hardware script adds under /etc/initcpio, and the
# module options its modconf hook copies in. One "sha256  path" line per file
# under the root $1, paths relative to it, sorted; a symlink is hashed as the
# name it points to. The installer reads the target's the same way
# (phases_impl._initramfs_inputs) and builds the initramfs on the machine when
# they differ.
initramfs_inputs() {
  local root=$1 path hash
  while IFS= read -r -d '' path; do
    if [[ -L $root/$path ]]; then
      hash=$(readlink "$root/$path" | sha256sum)
    else
      hash=$(sha256sum <"$root/$path")
    fi
    printf '%s  %s\n' "${hash%% *}" "$path"
  done < <(cd "$root" && find etc/mkinitcpio.conf etc/mkinitcpio.conf.d etc/initcpio etc/modprobe.d usr/lib/modprobe.d \
    \( -type f -o -type l \) -print0 2>/dev/null | LC_ALL=C sort -z)
}

# Build /var/lib/omarchy-iso/prebuilt-initramfs.img in the image at $root for
# its kernel $image_kver, and record what the installer checks before it uses
# it. Each step returns on failure: set -e does not apply in a function whose
# status the caller tests.
build_prebuilt_initramfs() {
  local dir=/var/lib/omarchy-iso hook
  local image=$dir/prebuilt-initramfs.img

  # /usr/bin/mkinitcpio, as omarchy-boot-rebuild calls it: the one first in
  # PATH is limine-mkinitcpio-hook's wrapper, which answers for plain
  # mkinitcpio whatever this did.
  arch-chroot "$root" /usr/bin/mkinitcpio -k "$image_kver" -g "$image" -S autodetect,kms 2>&1 | tail -25 || return 1
  [[ -s $root$image ]] || return 1

  # The hook set is the platform's baseline (00-omarchy-hooks.conf), read on
  # the build host: make sure it is the busybox one systemd-boot needs, with
  # the encrypt hook for cryptdevice= and Omarchy's snapshot and restore hooks.
  arch-chroot "$root" lsinitcpio "$image" >"$work/prebuilt-initramfs.list" || return 1
  for hook in encrypt omarchy-snapshot-overlay omarchy-restore; do
    if ! grep -qx "hooks/$hook" "$work/prebuilt-initramfs.list"; then
      echo "WARNING: the pre-built initramfs has no $hook hook" >&2
      return 1
    fi
  done

  printf '%s\n' "$image_kernel" >"$root$dir/prebuilt-initramfs.kernel"
  printf '%s\n' "$image_kver" >"$root$dir/prebuilt-initramfs.kver"
  # The console keymap the keymap hook compiled in, which the hashed inputs
  # below don't cover (vconsole.conf).
  ( [ -f "$root/etc/vconsole.conf" ] && . "$root/etc/vconsole.conf"; printf '%s\n' "${KEYMAP:-}" ) \
    >"$root$dir/prebuilt-initramfs.keymap"
  initramfs_inputs "$root" >"$root$dir/prebuilt-initramfs.inputs"
}

# Layers: what one kind of machine adds to the image on disk, packed next to
# the image for the installer to extract (phases_impl._apply_platform_layer).
# Installing the NVIDIA stack at install time took 22.6s on an N1x, 16s of it
# depmod and ldconfig reading the freshly written disk cold; extracting the
# same files takes a second or two. The image itself stays generic. A layer is
# named for a platform (aarch64-n1x) or for a hardware layer file (below).
layer_path() {
  printf '%s/omarchy-layer.%s.tar.zst\n' "${output%/*}" "$1"
}

# Pack the overlay's upper directory $1, the files pacstrap and its hooks wrote
# over the image, as layer $2. Paths the target makes or owns for itself
# are left out: mount points, caches and logs, the sync databases (the image
# ships its own), and the keyring the installer creates per machine.
write_layer() {
  local upper=$1 name=$2 layer zstd_level=15
  [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]] && zstd_level=1
  layer=$(layer_path "$name")

  # tar has no way to say "delete": an overlay whiteout (a 0:0 character
  # device) or an opaque directory in the upper layer would be extracted as
  # junk. A pacstrap of new packages deletes nothing; fail if one did.
  if [[ -n $(find "$upper" -type c -print -quit) ]] ||
    getfattr -R --absolute-names -d -m '^trusted\.overlay\.opaque' "$upper" 2>/dev/null | grep -q .; then
    echo "ERROR: the $name layer deletes files from the image; it cannot be packed as a tarball" >&2
    return 1
  fi

  tar -C "$upper" --numeric-owner --acls --xattrs --xattrs-include='*' \
    --xattrs-exclude='trusted.overlay.*' \
    --exclude=./boot --exclude=./dev --exclude=./proc --exclude=./sys \
    --exclude=./run --exclude=./tmp --exclude=./var/cache --exclude=./var/log \
    --exclude=./var/tmp --exclude=./var/lib/pacman/sync \
    --exclude=./etc/pacman.d/gnupg \
    -cf - . | zstd -q -T0 "-$zstd_level" -o "$layer" || return 1
  echo "Layer $name: $(du -h "$layer" | cut -f1) at $layer"
}

# Install packages $2... into the overlay at $1 as the installer would, from
# the image's mirror, and leave what the installed system's pacman hooks would
# have, whether or not the building system has those hooks: the module index
# and linker cache cover the new modules and libraries, and the packages'
# system users exist.
install_layer_packages() {
  local merged=$1
  shift
  pacstrap -C "$effective_pacman_conf" -c -G -M "$merged" --needed "$@" || return 1
  arch-chroot "$merged" depmod "$image_kver" || return 1
  arch-chroot "$merged" ldconfig || return 1
  systemd-sysusers --root="$merged" || return 1
}

# Run $1 <merged> <upper> [args...] on a throwaway overlay of $root, so what it
# installs never reaches the image itself.
with_image_overlay() {
  local run=$1 overlay status=0
  shift
  overlay=$(mktemp -d)
  mkdir -p "$overlay/rw" "$overlay/merged"
  # tmpfs for the upper layer: the image's btrfs has no room to spare, and the
  # builder's own root is an overlay, which cannot be an upper layer.
  if ! mount -t tmpfs -o size=6G omarchy-layer "$overlay/rw"; then
    rm -rf "$overlay"
    return 1
  fi
  mkdir -p "$overlay/rw/upper" "$overlay/rw/work"
  if mount -t overlay omarchy-layer \
       -o "lowerdir=$root,upperdir=$overlay/rw/upper,workdir=$overlay/rw/work" "$overlay/merged"; then
    "$run" "$overlay/merged" "$overlay/rw/upper" "$@" || status=1
    umount -R "$overlay/merged" || status=1
  else
    status=1
  fi
  umount "$overlay/rw" || status=1
  rm -rf "$overlay"
  return "$status"
}

# Hardware layers: what Omarchy's hardware scripts install on one kind of
# machine, packed like the N1x layer, and extracted only where the layer's own
# check passes (phases_impl._hardware_layer). Each <name>.layer in
# $OMARCHY_HARDWARE_LAYERS sets layer_arch and layer_packages and defines
# layer_matches, which only the installer runs.
hardware_layers=${OMARCHY_HARDWARE_LAYERS:-}

# The packages hardware layer file $1 installs on this build's architecture.
hardware_layer_packages() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  bash -c 'source "$1" && [[ $layer_arch == "$2" ]] && printf "%s\n" "${layer_packages[@]}"' _ "$1" "$(uname -m)"
}

# Omarchy's hardware scripts install these packages once the user exists, and
# a scriptlet may act on that user: intel-ipu7-camera's adds them to the video
# group. So a hardware layer is installed with --noscriptlet, and the packages
# that carry a scriptlet are listed for the installer to run once the user
# exists (phases_impl._run_layer_scriptlets).
build_hardware_layer_in() {
  local merged=$1 upper=$2 name=$3 logged=0
  shift 3
  [[ -f $merged/var/log/pacman.log ]] && logged=$(wc -l <"$merged/var/log/pacman.log")
  install_layer_packages "$merged" --noscriptlet "$@" || return 1
  record_layer_scriptlets "$merged" "$logged" || return 1
  write_layer "$upper" "$name"
}

# List in /var/lib/omarchy-iso/layer-scriptlets of the overlay at $1, as
# "name version" in the order pacman installed them after line $2 of its log,
# the packages that carry a scriptlet.
record_layer_scriptlets() {
  local merged=$1 skip=$2 name version list
  list=$merged/var/lib/omarchy-iso/layer-scriptlets
  [[ -f $merged/var/log/pacman.log ]] || return 1
  mkdir -p "${list%/*}" || return 1
  : >"$list" || return 1
  while read -r name version; do
    if [[ -f $merged/var/lib/pacman/local/$name-$version/install ]]; then
      printf '%s %s\n' "$name" "$version" >>"$list" || return 1
    fi
  done < <(tail -n +"$((skip + 1))" "$merged/var/log/pacman.log" |
    sed -n 's/^.*\[ALPM\] installed \([^ ]*\) (\(.*\))$/\1 \2/p')
}

build_hardware_layers() {
  local file name
  local -a packages
  [[ -n $hardware_layers && -d $hardware_layers ]] || return 0
  for file in "$hardware_layers"/*.layer; do
    [[ -f $file ]] || continue
    name=${file##*/}
    name=${name%.layer}
    mapfile -t packages < <(hardware_layer_packages "$file")
    ((${#packages[@]})) || continue
    echo "Packing the $name hardware layer: ${packages[*]}"
    if ! with_image_overlay build_hardware_layer_in "$name" "${packages[@]}"; then
      echo "WARNING: no $name layer; those machines install its packages at install time"
      rm -f "$(layer_path "$name")"
    fi
  done
}

# Set up N1x's boot-time state in the overlay at $1 (upper directory $2), pack
# its packages as the N1x layer, and build its UKI there. Each step returns on
# failure: set -e does not apply in a function whose status the caller tests.
build_n1x_uki_in() {
  local merged=$1 upper=$2 line
  local -a modules=(thunderbolt) line_modules n1x_packages

  # Every package the N1x list adds to the image, as the installer would
  # install them (_platform_delta_packages), from the same mirror.
  mapfile -t n1x_packages < <(grep -hv '^\s*#\|^\s*$' "$merged/usr/share/omarchy/install/omarchy-aarch64-n1x.packages")
  ((${#n1x_packages[@]})) || return 1
  install_layer_packages "$merged" "${n1x_packages[@]}" || return 1

  # Before anything below writes boot-time state into the overlay.
  write_layer "$upper" aarch64-n1x || return 1

  # As n1x.sh sets up an N1x whose GPU drives the panel: nvidia-drm's fbdev
  # draws the console and Plymouth's LUKS prompt.
  printf '%s\n' 'options nvidia_drm modeset=1 fbdev=1' >"$merged/etc/modprobe.d/nvidia.conf" || return 1

  # n1x.sh lights the dim power-on panel for the LUKS prompt with a busybox
  # hook, which a systemd initramfs never runs. A udev rule does the same in
  # both: write the backlight once nvidia_drm registers it.
  install -d "$merged/etc/udev/rules.d" "$merged/etc/initcpio/install" || return 1
  cat >"$merged/etc/udev/rules.d/90-omarchy-n1x-boot-brightness.rules" <<'RULE' || return 1
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="nvidia_0", ATTR{brightness}="60"
RULE
  cat >"$merged/etc/initcpio/install/sd-omarchy-n1x-boot-brightness" <<'INSTALL' || return 1
#!/usr/bin/env bash
build() {
    add_file /etc/udev/rules.d/90-omarchy-n1x-boot-brightness.rules /usr/lib/udev/rules.d/90-omarchy-n1x-boot-brightness.rules
}
help() {
    cat <<HELPEOF
Light the NVIDIA N1x panel for Plymouth's LUKS prompt.
HELPEOF
}
INSTALL

  # The generic UKI's config, with the N1x modules and the brightness hook.
  for line in "${n1x_lines[@]}"; do
    eval "line_modules=${line#*=}"
    modules+=("${line_modules[@]}")
  done
  sed -E \
    -e "s/^MODULES=.*/MODULES=(${modules[*]})/" \
    -e 's/ plymouth / plymouth sd-omarchy-n1x-boot-brightness /' \
    "$root/etc/mkinitcpio-prebuilt-uki.conf" >"$merged/etc/mkinitcpio-prebuilt-uki-n1x.conf" || return 1
  grep -q " plymouth sd-omarchy-n1x-boot-brightness " "$merged/etc/mkinitcpio-prebuilt-uki-n1x.conf" || return 1

  echo "Pre-building the N1x UKI (modules: ${modules[*]})"
  arch-chroot "$merged" mkinitcpio \
    -k "/usr/lib/modules/${image_kver}/vmlinuz" \
    -c /etc/mkinitcpio-prebuilt-uki-n1x.conf \
    --cmdline /etc/kernel/cmdline.prebuilt-uki \
    -U /var/lib/omarchy-iso/prebuilt-uki-n1x.efi \
    -S autodetect 2>&1 | tail -25
  [[ -f "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" ]] || return 1
  n1x_prebuilt_uki_size_ok "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" || return 1
  install -m 0644 "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" || return 1
  echo "Pre-built N1x UKI: $(du -h "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" | cut -f1)"
  # The lines an N1x install will have: the image's own and n1x.sh's.
  { cat "$root/var/lib/omarchy-iso/prebuilt-uki.modules"; printf '%s\n' "${n1x_lines[@]}"; } |
    sort -u >"$root/var/lib/omarchy-iso/prebuilt-uki-n1x.modules"
}

# Build /var/lib/omarchy-iso/prebuilt-uki-n1x.efi from a throwaway overlay of
# $root. Runs while the generic UKI's config and cmdline are still in $root.
build_n1x_prebuilt_uki() {
  local -a n1x_lines
  mapfile -t n1x_lines < <(n1x_module_lines "$1")
  if ((${#n1x_lines[@]} == 0)); then
    echo "WARNING: $1 writes no MODULES lines" >&2
    return 1
  fi
  with_image_overlay build_n1x_uki_in
}

pacman_conf="${1:-}"
output="${2:-}"
shift 2 || true
packages=("$@")

if [[ -z $pacman_conf || -z $output || ${#packages[@]} -eq 0 ]]; then
  echo "Usage: build-root-image.sh <pacman.conf> <output.img.zst> <package>..." >&2
  exit 1
fi
if [[ ! -r $pacman_conf ]]; then
  echo "ERROR: pacman config not readable: $pacman_conf" >&2
  exit 1
fi

# Forced zstd at level 15 by default: btrfs's incompressibility heuristic
# declines a lot of data in this tree that zstd handles fine, and the image is
# written to the target as it is. To avoid stalling single-threaded pacstrap on
# btrfs writeback, pacstrap and pre-build steps run in an uncompressed staging
# root and copy-tree-parallel.py then populates the mounted btrfs across every
# CPU. Under OMARCHY_FAST_COMPRESSION=1 (omarchy-iso-make --fast), mount btrfs
# at compress-force=zstd:1 up front and pacstrap directly into it.
#
# Forced in both modes for correctness, not just size: omarchy-image-write
# (and the dd fallback's conv=sparse) skips every all-zero frame, leaving
# whatever the target's LUKS volume held there. Only forced compression
# guarantees no file data is stored as a raw run of zeros. Without it, a file
# btrfs's heuristic marks incompressible keeps its zero padding raw, and the
# installed copy fails its checksum (EIO reading prebuilt-uki-n1x.efi).
IMAGE_COMPRESS="compress-force=zstd:15"
if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
  IMAGE_COMPRESS="compress-force=zstd:1"
fi
# Name of the image's one subvolume. The installer renames it to @ after the
# write (phases_impl.ROOT_IMAGE_SUBVOLUME).
IMAGE_SUBVOLUME="omarchy-root"

mount_root_btrfs() {
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
  mount -o "$IMAGE_COMPRESS,noatime,commit=600" "$loop" "$mnt"
  btrfs subvolume create "$mnt/$IMAGE_SUBVOLUME" >/dev/null
}

# Boot-image pacman hooks that must not run while the image is built: there is
# no kernel in the image and no ESP to deploy to. Point HookDir at a private
# directory in $work rather than mutating /etc/pacman.d/hooks globally, so
# concurrent pacstrap runs (like mkarchiso) are unaffected and a crash leaves
# no stale masks behind. Keep in step with DEFERRED_BOOT_HOOKS in
# configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py.
deferred_boot_hooks=(
  60-mkinitcpio-remove.hook
  60-limine-mkinitcpio-remove-pre.hook
  80-limine-efi-deploy.hook
  90-limine-mkinitcpio-remove-post.hook
  90-mkinitcpio-install.hook
)

work=$(mktemp -d /tmp/omarchy-root-image.XXXXXX)
stage="$work/stage"
backing="$work/image.btrfs"
mnt="$work/mnt"
loop=""

# Anything that touches a keyring under the image (pacman-key in a scriptlet,
# say) starts a gpg-agent for that homedir and leaves it running; until it is
# gone the image cannot be unmounted. Nothing should, as no keyring exists in
# the image, but kill whatever did.
stop_image_gpg_agents() {
  local dir
  for dir in "$stage" "$mnt/$IMAGE_SUBVOLUME"; do
    [[ -d "$dir/etc/pacman.d/gnupg" ]] || continue
    gpgconf --homedir "$dir/etc/pacman.d/gnupg" --kill all 2>/dev/null || true
    pkill -f "$dir/etc/pacman.d/gnupg" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?
  set +e
  stop_image_gpg_agents
  if mountpoint -q "$stage" 2>/dev/null; then
    sleep 1
    umount -R "$stage" || echo "WARNING: $stage is still mounted; leaving $work in place" >&2
  fi
  if mountpoint -q "$mnt" 2>/dev/null; then
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

mkdir -p "$work/hooks" "$stage"
for hook in "${deferred_boot_hooks[@]}"; do
  ln -s /dev/null "$work/hooks/$hook"
done
effective_pacman_conf="$work/pacman.conf"
sed "/^\[options\]/a HookDir = $work/hooks/" "$pacman_conf" >"$effective_pacman_conf"

if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
  mount_root_btrfs
  root="$mnt/$IMAGE_SUBVOLUME"
else
  # Stage in tmpfs when ample memory is free so pacstrap avoids disk I/O before
  # the parallel copy into the compressed btrfs image.
  mem_avail_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)
  if (( mem_avail_kb >= 20 * 1024 * 1024 )); then
    mount -t tmpfs -o size=16G,mode=0755 omarchy-root-stage "$stage" 2>/dev/null || true
  fi
  root="$stage"
fi

echo "Building root image with ${#packages[@]} packages"
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
pacstrap -C "$effective_pacman_conf" -c -G -M "$root" "${packages[@]}"
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

# Pre-bake the static UFW + ufw-docker rules into the root image while keeping
# UFW disabled (ENABLED=no in ufw.conf) so chroot ufw calls during install
# never reload the live ISO's kernel firewall. At install time firewall.sh sees
# its stamp and only flips ENABLED=yes and enables ufw.service.
firewall_sh="$root/usr/share/omarchy/install/config/firewall.sh"
if [[ -f $firewall_sh ]] && grep -q 'OMARCHY_FIREWALL_RULES_ONLY' "$firewall_sh"; then
  arch-chroot "$root" env OMARCHY_FIREWALL_RULES_ONLY=1 /bin/bash -eE -c 'source /usr/share/omarchy/install/config/firewall.sh'
  rm -f "$root"/etc/ufw/after*.rules-ufw-docker~*
  echo "Pre-baked static UFW + ufw-docker firewall rules"
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

# When the ISO builds the target's per-machine pacman keyring in tmpfs from
# prepare_live, let the runtime skip rebuilding it on btrfs during Phase 4
# (~3 s on aarch64). TODO: drop this patch once the runtime package carries it.
keyring_helper_sh="$root/usr/share/omarchy/install/helpers/pacman-keyring.sh"
if [[ -f $keyring_helper_sh ]] && ! grep -q 'OMARCHY_KEYRING_MANAGED_BY_ISO' "$keyring_helper_sh"; then
  sed -i \
    -e '/^omarchy_pacman_keyring_start() {/a\  [[ ${OMARCHY_KEYRING_MANAGED_BY_ISO:-0} == "1" ]] && return 0' \
    -e '/^omarchy_pacman_keyring_finish() {/a\  [[ ${OMARCHY_KEYRING_MANAGED_BY_ISO:-0} == "1" ]] && return 0' \
    "$keyring_helper_sh"
  bash -n "$keyring_helper_sh" && echo "pacman-keyring.sh: honour OMARCHY_KEYRING_MANAGED_BY_ISO"
fi

# Package names no repository offers any more: follow the known renames in the
# image's install scripts, refuse to ship one that still asks for a dropped name.
bash "$(dirname -- "${BASH_SOURCE[0]}")/follow-renamed-packages.sh" "$root/usr/share/omarchy/install" \
  "${OMARCHY_RENAMED_PACKAGES:-}" "${OMARCHY_UNRESOLVED_PACKAGES:-}"

# The online repositories' indexes, so the installed system can install
# software before its first update (see ship-sync-databases.sh).
if [[ -n ${OMARCHY_IMAGE_SYNC_DBS:-} ]]; then
  bash "$(dirname -- "${BASH_SOURCE[0]}")/ship-sync-databases.sh" "$root" "$OMARCHY_IMAGE_SYNC_DBS"
fi

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
# The output directory persists between builds: no layer from an older one.
rm -f "${output%/*}"/omarchy-layer.*.tar.zst
if [[ -z $image_kver ]]; then
  echo "WARNING: no kernel version found under /usr/lib/modules/; skipping the UKI pre-build"
else
  # The kernel package this image carries: linux-omarchy since upstream made it
  # the default, stock linux before. The installer names the UKI
  # and its Limine entry after it.
  image_kernel=$(<"$root/usr/lib/modules/${image_kver}/pkgbase")
  echo "$image_kernel" >"$root/var/lib/omarchy-iso/prebuilt-uki.kernel"
  # The early-loading modules configured when this UKI is built. A machine whose
  # hardware scripts add to them (nvidia.sh, fix-t2.sh) builds its own UKI.
  { grep -hE '^\s*MODULES\s*\+?=' "$root"/etc/mkinitcpio.conf.d/*.conf 2>/dev/null || true; } |
    sed -E 's/\s+/ /g; s/^ //; s/ $//' | sort -u >"$root/var/lib/omarchy-iso/prebuilt-uki.modules"
  # The console keymap this UKI is built with. omarchy_hooks.conf runs the
  # `keymap` hook, which compiles the keymap named by /etc/vconsole.conf into
  # the initramfs at build time, and bundles vconsole.conf itself for Plymouth.
  # Both are fixed here, at image build, to whatever this image has: in
  # practice nothing, so mkinitcpio falls back to us. The installer writes the
  # user's choice into the target's /etc/vconsole.conf afterwards, which cannot
  # reach an initramfs that is only copied, so an install picking another
  # layout writes it into the room reserved below, or builds its own UKI
  # where an image has none. Recording the value is what lets the installer
  # tell the difference.
  #
  # The LUKS passphrase prompt runs from this initramfs, so a stale `us` makes
  # a passphrase enrolled under another layout untypeable and locks the owner
  # out of a fresh install (upstream omarchy#8196).
  ( [ -f "$root/etc/vconsole.conf" ] && . "$root/etc/vconsole.conf"; printf '%s\n' "${KEYMAP:-}" ) \
    >"$root/var/lib/omarchy-iso/prebuilt-uki.keymap"
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

  # No kms hook. With autodetect skipped it would add every DRM driver and its
  # firmware (nouveau's GSP firmware alone is ~110 MB): the UKI measured 247 MiB
  # with it. Limine boots a UKI as an EFI chainload into one contiguous block
  # below 4 GiB, and UKIs that size panic it on some laptops
  # (omacom/omarchy#5980), as a 241 MiB initramfs does GRUB (#128). Without
  # kms, Plymouth's LUKS prompt draws on the firmware framebuffer (simpledrm);
  # the installed system's own rebuilds autodetect and keep kms.
  # Room for the installer to write the install's keyboard layout into the
  # UKI in place (orchestrator/uki_vconsole.py), as for the cmdline below: an
  # install on another layout than us then has no UKI to build, 4.7 s of the
  # install. The initramfs gets every console keymap (1.3 MB), since
  # sd-vconsole adds only the one vconsole.conf names at build time, and an
  # /etc/vconsole.conf of one 512-byte comment line. add_file_early puts that
  # file in the early cpio, the uncompressed archive at the start of the
  # initramfs, where the installer finds its bytes and overwrites them. Until
  # then it is a comment, and the initramfs comes up in us as before.
  cat >"$root/usr/lib/initcpio/install/omarchy-vconsole-room" <<'INSTALL'
#!/usr/bin/env bash
build() {
    add_full_dir /usr/share/kbd/keymaps
    add_file_early /etc/vconsole.conf.prebuilt-uki /etc/vconsole.conf 644
}
INSTALL
  chmod 0755 "$root/usr/lib/initcpio/install/omarchy-vconsole-room"
  vconsole_room="# omarchy.vconsole_room "
  printf '%s%s\n' "$vconsole_room" "$(printf '%*s' $((512 - ${#vconsole_room} - 1)) '' | tr ' ' '#')" \
    >"$root/etc/vconsole.conf.prebuilt-uki"

  cat >"$root/etc/mkinitcpio-prebuilt-uki.conf" <<'CONF'
MODULES=(thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base systemd plymouth autodetect microcode modconf keyboard sd-vconsole omarchy-vconsole-room block sd-encrypt filesystems fsck sd-btrfs-overlayfs)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-T0)
CONF

  # Bundle the mount-event burst override into the pre-built systemd initramfs:
  # mkinitcpio's systemd hook does not copy /etc/systemd/system.conf.d/, so PID 1
  # in the initrd otherwise hits the default 5/s mount-monitor-dispatch rate
  # limit and stalls sysroot.mount for 1.0 s (systemd/systemd#28264). The N1x
  # UKI derives its config from this file and inherits FILES automatically.
  if [[ -f $root/etc/systemd/system.conf.d/20-mount-events.conf ]]; then
    echo 'FILES+=(/etc/systemd/system.conf.d/20-mount-events.conf)' >>"$root/etc/mkinitcpio-prebuilt-uki.conf"
  else
    echo "WARNING: /etc/systemd/system.conf.d/20-mount-events.conf missing from image; initrd mount rate limit override skipped"
  fi

  # Room for the installer to write the real cmdline into the UKI in place
  # (orchestrator/uki_cmdline.py): one placeholder parameter pads .cmdline to
  # 1800 bytes, under the kernel's 2048. A dotted name is a module parameter
  # to the kernel, so until it is overwritten it is ignored without a warning.
  prebuilt_cmdline=$(tr -s '\n ' ' ' <"$root/etc/kernel/cmdline")
  prebuilt_cmdline="${prebuilt_cmdline% } omarchy.cmdline_room="
  printf '%s%s\n' "$prebuilt_cmdline" "$(printf '%*s' $((1800 - ${#prebuilt_cmdline})) '' | tr ' ' 0)" \
    >"$root/etc/kernel/cmdline.prebuilt-uki"

  if [[ -n ${OMARCHY_SNAPDRAGON:-} ]]; then
    # A Snapdragon ISO installs only Snapdragon laptops, whose platform builds
    # its own UKI with board firmware and device trees, so shipping the generic
    # ~116 MiB pre-built UKI only bloats the root image and slows image writes.
    rm -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi"
    echo "Skipping generic pre-built UKI on Snapdragon image (platform builds its own)"
  else
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
        prebuilt_uki_size_ok "$root/var/lib/omarchy-iso/prebuilt-uki.efi" || exit 1
      else
        echo "WARNING: mkinitcpio ran but left no UKI; the installer will build one"
      fi
    else
      echo "WARNING: mkinitcpio failed; the installer will build the UKI"
      # Clean up any partial output that would upset btrfs shrink downstream.
      rm -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi"
    fi
  fi
  # N1x: a second pre-built UKI. Its hardware setup always adds the same
  # early-loading modules, the NVIDIA stack for early KMS and the I2C keyboard
  # for the LUKS prompt, so the generic UKI never fits it and every N1x built
  # its own at install, about 20s. This one is built with them, read from the
  # image's own n1x.sh so the two cannot drift, and recorded the same way; the
  # installer copies it where the machine's lines match (_n1x_prebuilt_uki).
  # The NVIDIA packages go into a throwaway overlay of the image, never into
  # the image itself. What they add is packed from that overlay as the N1x
  # layer, which the installer extracts on an N1x, so the driver in the UKI is
  # the one on disk.
  n1x_script="$root/usr/share/omarchy/install/hardware/n1x.sh"
  if [[ $(uname -m) == aarch64 && -z ${OMARCHY_SNAPDRAGON:-} && -f $n1x_script && -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi" ]]; then
    build_n1x_prebuilt_uki "$n1x_script" || {
      echo "WARNING: no N1x pre-built UKI or layer; N1x installs build their own and pacstrap the NVIDIA stack"
      rm -f "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.modules" \
        "$(layer_path aarch64-n1x)"
    }
  fi

  # systemd-boot's fast path, as the UKI is Limine's: the initramfs
  # omarchy-boot-switch install builds on the target, 4 s of the install, built
  # here once. The UKI's systemd hook set can't stand in: systemd-boot's boot
  # images need Omarchy's busybox hooks for snapshots and restores. So this is
  # the image's own mkinitcpio configuration, as the target would read it, made
  # generic the way the UKI is: autodetect skipped, and kms with it, which
  # without autodetect bundles every GPU's firmware (237 MB measured). The LUKS
  # prompt then draws on the firmware framebuffer, and the first kernel update
  # builds the machine's own, with both. The installer passes it to
  # omarchy-boot-switch install (--initramfs) where nothing it is built from
  # changed on the machine (phases_impl._prebuilt_initramfs), and builds one
  # otherwise. A Snapdragon ISO installs only Snapdragon laptops, whose
  # platform builds its own, so it ships none.
  rm -f "$root"/var/lib/omarchy-iso/prebuilt-initramfs.*
  # An image whose omarchy-boot-rebuild can't take it (an older omarchy) gets
  # none: installs build theirs, as before.
  if ! grep -q -- '--initramfs' "$root/usr/bin/omarchy-boot-rebuild" 2>/dev/null; then
    echo "omarchy-boot-rebuild takes no pre-built initramfs; none is built"
  elif [[ -z ${OMARCHY_SNAPDRAGON:-} ]]; then
    echo "Pre-building systemd-boot's initramfs in the image (kver=$image_kver, the image's hooks, no autodetect, no kms)"
    if build_prebuilt_initramfs; then
      echo "Pre-built initramfs: $(du -h "$root/var/lib/omarchy-iso/prebuilt-initramfs.img" | cut -f1)"
      prebuilt_initramfs_size_ok "$root/var/lib/omarchy-iso/prebuilt-initramfs.img" || exit 1
    else
      echo "WARNING: no pre-built initramfs; systemd-boot installs build theirs"
      rm -f "$root"/var/lib/omarchy-iso/prebuilt-initramfs.*
    fi
  fi

  # Only this build uses these; the installed system has no use for them.
  rm -f "$root/etc/mkinitcpio-prebuilt-uki.conf" "$root/etc/kernel/cmdline.prebuilt-uki" \
    "$root/etc/vconsole.conf.prebuilt-uki" "$root/usr/lib/initcpio/install/omarchy-vconsole-room"
fi

# Hardware layers, now that the image's tree is final: each is the difference
# its packages make to the image as it ships.
if [[ -n $image_kver ]]; then
  build_hardware_layers
fi

if [[ ${OMARCHY_FAST_COMPRESSION:-} != 1 ]]; then
  # Now create the compressed btrfs filesystem and populate it in parallel across
  # every CPU so zstd:15 runs at full host parallelism, then free the staging tree
  # before shrinking and packing.
  mount_root_btrfs

  echo "Populating btrfs root image with $IMAGE_COMPRESS across $(nproc) CPUs"
  copy_start=$(date +%s)
  python3 "$(dirname -- "${BASH_SOURCE[0]}")/copy-tree-parallel.py" "$stage" "$mnt/$IMAGE_SUBVOLUME"
  sync
  echo "Populated btrfs root image in $(( $(date +%s) - copy_start ))s"
  if mountpoint -q "$stage" 2>/dev/null; then
    umount -R "$stage"
  fi
  rm -rf "$stage"
fi

# The image is the loop backing file itself: the same on-disk bytes, written
# to the target partition as they are.
#
# Shrink the filesystem and truncate the backing file first: xorriso stores a
# file at its apparent size, so a sparse 24 GiB backing file would overflow
# the medium even with 5 GiB in use.
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
  image_size=${OMARCHY_IMAGE_SIZE:-24G}
  shrink_mb=$(( ${image_size%G} * 1024 ))
fi
# Free space inside the image still holds what the build and the shrink's
# relocations left there. Discard it: the loop device punches holes in the
# backing file, holes read back as zeros, and pack compresses them to nothing
# (or skips a whole zero frame). Measured: 2 GiB trimmed, 83.6 MB (2.0%) off
# the packed image, 63 more zero frames.
fstrim -v "$mnt" || echo "WARNING: fstrim failed; free space ships as whatever it holds"
sync
umount "$mnt"
losetup -d "$loop"
loop=""
truncate -s "${shrink_mb}M" "$backing"

# Compress the image for the ISO. zstd collapses the unused space; the data
# is already compressed inside btrfs and shrinks little. Measured: 6.3 GB
# becomes 3.8 GB at zstd -3.
#
# As independent 256 KiB frames (level 3, a checksum each), which is what lets
# omarchy-image-write decode and write it on every core at install time:
# 0.9 s instead of 2.5 s through zstdcat | dd on a 990 PRO. Framing costs
# 1.3% (55 MB). It is still one valid .zst; zstd -d reads it unchanged.
echo "Packing the root image as 256 KiB zstd frames"
omarchy-image-write pack "$backing" "$output"
echo "Root image: $(du -h "$output" | cut -f1) at $output (from ${shrink_mb}M apparent input)"
