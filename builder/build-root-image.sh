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
# Usage: build-root-image.sh <pacman.conf> <output> <package>...
#
#   pacman.conf     Config whose repositories resolve every package; its
#                   CacheDir must hold the package files so nothing is copied.
#   output          Where to write the image: omarchy-root.sfs, a squashfs
#                   holding the raw image as omarchy-root.img, which the
#                   installer writes and Try Omarchy boots; or an .img.zst,
#                   packed as zstd frames (omarchy-image-write pack).
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
#   OMARCHY_TRY_LAYER           Where to write the Try layer for this image
#                               (builder/build-try-layer.sh); none when unset.
#   OMARCHY_TRY_CHANNEL         The channel the Try session's pacman uses
#                               (stable, rc or edge; default stable).
#   OMARCHY_TRY_NODE_DIR        The ISO's bundled Node tarball, for a runtime
#                               that unpacks it while provisioning the user.
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

install_uki_tmp_files() {
  local dst=$1
  install -Dm0755 "$uki_tmp/omarchy-vconsole-room" "$dst/usr/lib/initcpio/install/omarchy-vconsole-room" || return 1
  install -Dm0644 "$uki_tmp/vconsole.conf.prebuilt-uki" "$dst/etc/vconsole.conf.prebuilt-uki" || return 1
  install -Dm0644 "$uki_tmp/mkinitcpio-prebuilt-uki.conf" "$dst/etc/mkinitcpio-prebuilt-uki.conf" || return 1
  install -Dm0644 "$uki_tmp/cmdline.prebuilt-uki" "$dst/etc/kernel/cmdline.prebuilt-uki" || return 1
}

build_generic_uki_in() {
  local merged=$1 _upper=$2 out_dir=$3
  install_uki_tmp_files "$merged" || return 1
  echo "Pre-building the UKI in the image (kver=$image_kver, generic cmdline, systemd and sd-encrypt hooks, no autodetect)"
  if arch-chroot "$merged" mkinitcpio \
       -k "/usr/lib/modules/${image_kver}/vmlinuz" \
       -c /etc/mkinitcpio-prebuilt-uki.conf \
       --cmdline /etc/kernel/cmdline.prebuilt-uki \
       -U /var/lib/omarchy-iso/prebuilt-uki.efi \
       -S autodetect 2>&1 | tail -25 ; then
    if [[ -f "$merged/var/lib/omarchy-iso/prebuilt-uki.efi" ]]; then
      echo "Pre-built UKI: $(du -h "$merged/var/lib/omarchy-iso/prebuilt-uki.efi" | cut -f1)"
      prebuilt_uki_size_ok "$merged/var/lib/omarchy-iso/prebuilt-uki.efi" || return 2
      cp -p "$merged/var/lib/omarchy-iso/prebuilt-uki.efi" "$out_dir/prebuilt-uki.efi" || return 1
    else
      echo "WARNING: mkinitcpio ran but left no UKI; the installer will build one"
      return 3
    fi
  else
    echo "WARNING: mkinitcpio failed; the installer will build the UKI"
    return 1
  fi
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
  # Keep hardware-probing ALPM hooks (60-ath12k-board-fallback.hook) from
  # inspecting the build host's PCI tree and writing host-specific files into
  # the layer.
  ATH12K_BOARD_SYSFS=/nonexistent \
    pacstrap -C "$effective_pacman_conf" -c -G -M "$merged" --needed "$@" || return 1
  # Skip redundant depmod/ldconfig when pacstrap's own 60-depmod.hook / libalpm
  # already wrote fresh indexes into this empty overlay upper directory.
  if [[ -z ${layer_upper:-} || ! -f $layer_upper/usr/lib/modules/$image_kver/modules.dep ]]; then
    arch-chroot "$merged" depmod "$image_kver" || return 1
  fi
  if [[ -z ${layer_upper:-} || ! -f $layer_upper/etc/ld.so.cache ]]; then
    arch-chroot "$merged" ldconfig || return 1
  fi
  systemd-sysusers --root="$merged" || return 1
}

# Run $1 <merged> <upper> [args...] on a throwaway overlay of $root, so what it
# installs never reaches the image itself.
stop_pid_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    stop_pid_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

_with_image_overlay() {
  local run=$1 overlay child_pid="" status=0
  shift
  overlay=$(mktemp -d)
  cleanup_overlay() {
    local rc=$?
    set +e
    if [[ -n $child_pid ]]; then
      stop_pid_tree "$child_pid"
      wait "$child_pid" 2>/dev/null || true
    fi
    if mountpoint -q "$overlay/merged" 2>/dev/null; then
      umount -R "$overlay/merged" 2>/dev/null || { sleep 0.2; umount -R "$overlay/merged" 2>/dev/null || true; }
    fi
    if mountpoint -q "$overlay/rw" 2>/dev/null; then
      umount "$overlay/rw" 2>/dev/null || { sleep 0.2; umount "$overlay/rw" 2>/dev/null || true; }
    fi
    rm -rf "$overlay"
    exit "$rc"
  }
  trap cleanup_overlay EXIT
  trap 'exit 143' TERM INT
  mkdir -p "$overlay/rw" "$overlay/merged"
  # tmpfs for the upper layer: the image's btrfs has no room to spare, and the
  # builder's own root is an overlay, which cannot be an upper layer.
  mount -t tmpfs -o size=6G omarchy-layer "$overlay/rw" || exit 1
  mkdir -p "$overlay/rw/upper" "$overlay/rw/work"
  if mount -t overlay omarchy-layer \
       -o "lowerdir=$root,upperdir=$overlay/rw/upper,workdir=$overlay/rw/work" "$overlay/merged"; then
    "$run" "$overlay/merged" "$overlay/rw/upper" "$@" &
    child_pid=$!
    wait "$child_pid" || status=$?
    child_pid=""
    umount -R "$overlay/merged" || status=1
  else
    status=1
  fi
  umount "$overlay/rw" || status=1
  exit "$status"
}

with_image_overlay() {
  if (( BASH_SUBSHELL > 0 )); then
    _with_image_overlay "$@"
  else
    ( _with_image_overlay "$@" )
  fi
}

# Hardware layers: what Omarchy's hardware scripts install on one kind of
# machine, packed like the N1x layer, and extracted only where the layer's own
# check passes (phases_impl._hardware_layer). Each <name>.layer in
# $OMARCHY_HARDWARE_LAYERS sets layer_arch and layer_packages and defines
# layer_matches, which only the installer runs.
hardware_layers=${OMARCHY_HARDWARE_LAYERS:-}

# The packages hardware layer file $1 installs on this build's architecture
# (and variant: layer_snapdragon=1 layers are packed only on Snapdragon ISOs).
hardware_layer_packages() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  bash -c 'source "$1" && [[ $layer_arch == "$2" ]] && [[ ${layer_snapdragon:-0} != 1 || -n ${OMARCHY_SNAPDRAGON:-} ]] && printf "%s\n" "${layer_packages[@]}"' _ "$1" "$(uname -m)"
}

# Omarchy's hardware scripts install these packages once the user exists, and
# a scriptlet may act on that user: intel-ipu7-camera's adds them to the video
# group. So a hardware layer is installed with --noscriptlet, and the packages
# that carry a scriptlet are listed for the installer to run once the user
# exists (phases_impl._run_layer_scriptlets).
build_hardware_layer_in() {
  local merged=$1 upper=$2 name=$3 logged=0 layer_upper=$2
  shift 3
  echo "Packing the $name hardware layer: $*"
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
  local file name log i status
  local -a packages names=() pids=() logs=()
  [[ -n $hardware_layers && -d $hardware_layers ]] || return 0
  hardware_layer_pids=()
  hardware_layer_names=()
  hardware_layer_logs=()
  for file in "$hardware_layers"/*.layer; do
    [[ -f $file ]] || continue
    name=${file##*/}
    name=${name%.layer}
    mapfile -t packages < <(hardware_layer_packages "$file")
    ((${#packages[@]})) || continue
    log="${work:-/tmp}/hw-layer-$name.log"
    if [[ ${hardware_layers_async:-0} == 1 ]]; then
      with_image_overlay build_hardware_layer_in "$name" "${packages[@]}" >"$log" 2>&1 &
      hardware_layer_pids+=($!)
      hardware_layer_names+=("$name")
      hardware_layer_logs+=("$log")
    else
      names+=("$name")
      logs+=("$log")
      with_image_overlay build_hardware_layer_in "$name" "${packages[@]}" >"$log" 2>&1 &
      pids+=($!)
      hardware_layer_pids+=($!)
    fi
  done
  if [[ ${hardware_layers_async:-0} != 1 ]]; then
    for i in "${!pids[@]}"; do
      status=0
      wait "${pids[i]}" || status=$?
      [[ -f ${logs[i]} ]] && cat "${logs[i]}"
      rm -f "${logs[i]}"
      if (( status != 0 )); then
        echo "WARNING: no ${names[i]} layer; those machines install its packages at install time"
        rm -f "$(layer_path "${names[i]}")"
      fi
    done
    hardware_layer_pids=()
  fi
}

# Build prebuilt-uki-n1x.efi inside an overlay whose lower layer already holds
# the N1x packages (from install_layer_packages), writing outputs to $2.
build_n1x_uki_stage() {
  local merged=$1 out_dir=${2:-$root/var/lib/omarchy-iso} line
  local -a modules=(thunderbolt) line_modules

  if [[ -n ${uki_tmp:-} && -d ${uki_tmp:-} ]]; then
    install_uki_tmp_files "$merged" || return 1
  fi

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
    "$merged/etc/mkinitcpio-prebuilt-uki.conf" >"$merged/etc/mkinitcpio-prebuilt-uki-n1x.conf" || return 1
  grep -q " plymouth sd-omarchy-n1x-boot-brightness " "$merged/etc/mkinitcpio-prebuilt-uki-n1x.conf" || return 1

  echo "Pre-building the N1x UKI (modules: ${modules[*]})"
  arch-chroot "$merged" mkinitcpio \
    -k "/usr/lib/modules/${image_kver}/vmlinuz" \
    -c /etc/mkinitcpio-prebuilt-uki-n1x.conf \
    --cmdline /etc/kernel/cmdline.prebuilt-uki \
    -U /var/lib/omarchy-iso/prebuilt-uki-n1x.efi \
    -S autodetect 2>&1 | tail -25 || return 1
  [[ -f "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" ]] || return 1
  n1x_prebuilt_uki_size_ok "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" || return 1
  install -m 0644 "$merged/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" "$out_dir/prebuilt-uki-n1x.efi" || return 1
  echo "Pre-built N1x UKI: $(du -h "$out_dir/prebuilt-uki-n1x.efi" | cut -f1)"
  # The lines an N1x install will have: the image's own and n1x.sh's.
  { cat "$root/var/lib/omarchy-iso/prebuilt-uki.modules"; printf '%s\n' "${n1x_lines[@]}"; } |
    sort -u >"$out_dir/prebuilt-uki-n1x.modules"
}

# Set up N1x's packages in a throwaway overlay of $root, freeze its upper
# directory read-only, then pack the N1x layer tarball concurrently with
# building prebuilt-uki-n1x.efi, where the image gets pre-built UKIs, in a
# second overlay stacked over it.
_build_n1x_stacked_overlay() {
  local out_dir=${1:-$root/var/lib/omarchy-iso}
  local overlay child_pid="" layer_pid="" uki_pid="" status=0 layer_rc=0 uki_rc=0
  local -a n1x_packages
  overlay=$(mktemp -d)
  cleanup_n1x_overlay() {
    local rc=$? pid mp
    set +e
    for pid in "$child_pid" "$layer_pid" "$uki_pid"; do
      [[ -n $pid ]] || continue
      stop_pid_tree "$pid"
      wait "$pid" 2>/dev/null || true
    done
    for mp in "$overlay/uki-merged" "$overlay/uki-rw" "$overlay/merged" "$overlay/rw"; do
      if mountpoint -q "$mp" 2>/dev/null; then
        umount -R "$mp" 2>/dev/null || { sleep 0.2; umount -R "$mp" 2>/dev/null || true; }
      fi
    done
    rm -rf "$overlay"
    exit "$rc"
  }
  trap cleanup_n1x_overlay EXIT
  trap 'exit 143' TERM INT
  mkdir -p "$overlay/rw" "$overlay/merged" "$overlay/uki-rw" "$overlay/uki-merged"
  mount -t tmpfs -o size=6G omarchy-n1x-layer "$overlay/rw" || exit 1
  mkdir -p "$overlay/rw/upper" "$overlay/rw/work"
  mount -t overlay omarchy-n1x-layer \
    -o "lowerdir=$root,upperdir=$overlay/rw/upper,workdir=$overlay/rw/work" "$overlay/merged" || exit 1

  mapfile -t n1x_packages < <(grep -hv '^\s*#\|^\s*$' "$overlay/merged/usr/share/omarchy/install/omarchy-aarch64-n1x.packages")
  ((${#n1x_packages[@]})) || exit 1
  (
    layer_upper="$overlay/rw/upper"
    install_layer_packages "$overlay/merged" "${n1x_packages[@]}"
  ) &
  child_pid=$!
  wait "$child_pid" || status=$?
  child_pid=""
  umount -R "$overlay/merged" || status=1
  (( status == 0 )) || exit "$status"

  # $overlay/rw/upper is now unmounted and read-only: pack the N1x layer
  # concurrently with building the N1x UKI on a stacked overlay over it.
  write_layer "$overlay/rw/upper" aarch64-n1x >"$overlay/layer.log" 2>&1 &
  layer_pid=$!

  if (( ! prebuilt_ukis )); then
    :
  elif mount -t tmpfs -o size=4G omarchy-n1x-uki "$overlay/uki-rw" &&
     mkdir -p "$overlay/uki-rw/upper" "$overlay/uki-rw/work" &&
     mount -t overlay omarchy-n1x-uki \
       -o "lowerdir=$overlay/rw/upper:$root,upperdir=$overlay/uki-rw/upper,workdir=$overlay/uki-rw/work,index=off,metacopy=off" \
       "$overlay/uki-merged"; then
    build_n1x_uki_stage "$overlay/uki-merged" "$out_dir" >"$overlay/uki.log" 2>&1 &
    uki_pid=$!
  else
    uki_rc=1
  fi

  wait "$layer_pid" || layer_rc=$?
  layer_pid=""
  [[ -f $overlay/layer.log ]] && cat "$overlay/layer.log"

  if [[ -n $uki_pid ]]; then
    wait "$uki_pid" || uki_rc=$?
    uki_pid=""
  fi
  [[ -f $overlay/uki.log ]] && cat "$overlay/uki.log"

  if mountpoint -q "$overlay/uki-merged" 2>/dev/null; then
    umount -R "$overlay/uki-merged" || status=1
  fi
  if mountpoint -q "$overlay/uki-rw" 2>/dev/null; then
    umount "$overlay/uki-rw" || status=1
  fi
  umount "$overlay/rw" || status=1
  (( layer_rc == 0 && uki_rc == 0 )) || status=1
  exit "$status"
}

# The Snapdragon UKI carries the arm64 kernel (63 MiB), the Qualcomm early
# modules, Adreno microcode and all Snapdragon device trees (~15 MiB), so it
# uses the same 256 MiB ceiling as the N1x UKI.
qualcomm_prebuilt_uki_size_ok() {
  local bytes limit=$((256 * 1024 * 1024))
  bytes=$(stat -c %s "$1")
  if ((bytes > limit)); then
    echo "ERROR: the Qualcomm pre-built UKI is $bytes bytes, over the $limit limit" >&2
    return 1
  fi
}

# Every early-loading module name named by the image's own mkinitcpio drop-ins
# and Omarchy's Qualcomm hardware scripts under $1, normalized (no ?, - -> _),
# excluding qcom_q6v5_pas: loading the DSP driver early resets USB-C controllers
# and breaks USB-root installs, so only machines that explicitly ask for it
# (Surface Laptop 8) build their own UKI with it.
qualcomm_module_names() {
  local root=$1
  python3 - "$root" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
modules = set()

def extract(text):
    for m in re.finditer(r"^\s*MODULES\s*\+?=\(([^)]*)\)", text, re.M | re.S):
        body = "\n".join(line.split("#", 1)[0] for line in m.group(1).splitlines())
        for tok in body.split():
            tok = tok.strip("'\"")
            if not tok or tok.startswith("$"):
                continue
            name = tok.rstrip("?").replace("-", "_")
            if re.fullmatch(r"[A-Za-z0-9_]+", name) and name != "qcom_q6v5_pas":
                modules.add(name)

conf_dir = root / "etc" / "mkinitcpio.conf.d"
if conf_dir.is_dir():
    for conf in sorted(conf_dir.glob("*.conf")):
        extract(conf.read_text(errors="ignore"))

hw_dir = root / "usr" / "share" / "omarchy" / "install" / "hardware"
if hw_dir.is_dir():
    for script in sorted(hw_dir.rglob("*.sh")):
        text = script.read_text(errors="ignore")
        if "omarchy-hw-aarch64-qualcomm" in text and "mkinitcpio" in text:
            extract(text)

for name in sorted(modules):
    print(name)
PY
}

# Root board-level compatible string from each FDT (.dtb) file given as args.
qualcomm_dtb_compatibles() {
  python3 - "$@" <<'PY'
import struct, sys

def root_compatible(path):
    data = open(path, "rb").read()
    if len(data) < 40:
        return None
    magic, _, off_struct, off_strings, _, _, _, _, size_strings, size_struct = struct.unpack(">10I", data[:40])
    if magic != 0xD00DFEED:
        return None
    pos = off_struct
    end = off_struct + size_struct
    depth = 0
    while pos + 4 <= end:
        token = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4
        if token == 1:  # FDT_BEGIN_NODE
            nul = data.find(b"\x00", pos)
            if nul == -1:
                break
            pos = (nul + 4) & ~3
            depth += 1
        elif token == 2:  # FDT_END_NODE
            depth -= 1
            if depth == 0:
                break
        elif token == 3:  # FDT_PROP
            if pos + 8 > end:
                break
            plen, nameoff = struct.unpack(">II", data[pos:pos + 8])
            pos += 8
            val = data[pos:pos + plen]
            pos = (pos + plen + 3) & ~3
            if depth == 1:
                nstart = off_strings + nameoff
                nend = data.find(b"\x00", nstart)
                if nend != -1 and data[nstart:nend] == b"compatible":
                    first = val.split(b"\x00", 1)[0].decode("utf-8", errors="ignore")
                    return first or None
        elif token == 4:  # FDT_NOP
            continue
        elif token == 9:  # FDT_END
            break
        else:
            break
    return None

seen = set()
for p in sys.argv[1:]:
    c = root_compatible(p)
    if c:
        seen.add(c)
for c in sorted(seen):
    print(c)
PY
}

# Hash the Qualcomm UKI's non-drop-in initramfs inputs so the installer can
# detect modified mkinitcpio.conf, custom /etc/initcpio hooks, or unexpected
# /etc/modprobe.d overrides added by a board's hardware setup.
qualcomm_initramfs_inputs() {
  local root=$1 path hash
  while IFS= read -r -d '' path; do
    if [[ -L $root/$path ]]; then
      hash=$(readlink "$root/$path" | sha256sum)
    else
      hash=$(sha256sum <"$root/$path")
    fi
    printf '%s  %s\n' "${hash%% *}" "$path"
  done < <(cd "$root" && find etc/mkinitcpio.conf etc/initcpio etc/modprobe.d \
    \( -type f -o -type l \) -print0 2>/dev/null | LC_ALL=C sort -z)
}

# Adreno X1 / X2 GPU microcode shared by the Snapdragon display initramfs
# drop-ins (glymur-display.sh, hamoa-display.sh and board boot scripts), under
# 600 KiB total.
QUALCOMM_ADRENO_FIRMWARE=(
  qcom/gen70500_sqe.fw
  qcom/gen70500_gmu.bin
  qcom/gen71500_sqe.fw
  qcom/gen71500_gmu.bin
  qcom/gen80100_sqe.fw
  qcom/gen80100_gmu.bin
)

# Build /var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi in a throwaway overlay
# of $root with all Snapdragon DTBs (DeviceTreeAuto + HWIDs), the Qualcomm early
# modules that resolve in $image_kver, and the Adreno GPU microcode. Runs while
# the generic UKI's config and cmdline are still in $root.
build_qualcomm_uki_in() {
  local merged=$1 _upper=$2 out_dir=${3:-$root/var/lib/omarchy-iso}
  local stub=/usr/lib/systemd-stub-omarchy/linuxaa64.efi.stub
  local hwids=/usr/lib/systemd/boot/hwids/aa64
  local dtb_dir="$merged/boot/dtbs/$image_kernel/qcom"
  local mod fn fw suffix dir dtb sections n_dtb
  local -a loadable_modules=() covered_modules=() firmware_files=() recorded_firmware=() dtbs=() dtb_paths=()

  if [[ -n ${uki_tmp:-} && -d ${uki_tmp:-} ]]; then
    install_uki_tmp_files "$merged" || return 1
  fi

  [[ -f $merged$stub ]] || { echo "WARNING: $stub missing; skipping Qualcomm pre-built UKI" >&2; return 1; }
  [[ -d $merged$hwids ]] || { echo "WARNING: $hwids missing; skipping Qualcomm pre-built UKI" >&2; return 1; }

  # Match live-uki.sh and omarchy-update-qualcomm-device-trees: supported
  # Windows-on-ARM Snapdragon families, excluding *-el2.dtb variants whose
  # shared hardware IDs would sort ahead of and shadow their base DTBs.
  for dtb in \
    "$dtb_dir"/x1*.dtb "$dtb_dir"/hamoa*.dtb "$dtb_dir"/purwa*.dtb \
    "$dtb_dir"/glymur*.dtb "$dtb_dir"/mahua*.dtb "$dtb_dir"/kalambo*.dtb \
    "$dtb_dir"/sc8280xp*.dtb "$dtb_dir"/sc8180x*.dtb "$dtb_dir"/sdm850*.dtb \
    "$dtb_dir"/msm8998-{asus,hp,lenovo}*.dtb \
    "$dtb_dir"/sc7180-{acer,apcsilmic,ecs,lenovo,samsung,tcl}*.dtb \
    "$dtb_dir"/sc7280-{hp,samsung}*.dtb; do
    if [[ -f $dtb && $dtb != *-el2.dtb ]]; then
      dtbs+=("${dtb#"$merged"}")
      dtb_paths+=("$dtb")
    fi
  done
  ((${#dtbs[@]} > 0)) || { echo "WARNING: no Qualcomm DTBs in $dtb_dir; skipping Qualcomm pre-built UKI" >&2; return 1; }

  # Resolve inside $merged against $image_kver in a single chroot invocation
  # (rather than one arch-chroot mount/unmount cycle per module), preserving
  # exact per-module modinfo -F filename semantics for loadable, builtin, and
  # aliased modules.
  if ((${#qcom_modules[@]} == 1)); then
    mod=${qcom_modules[0]}
    fn=$(arch-chroot "$merged" modinfo -k "$image_kver" -F filename "$mod" 2>/dev/null || true)
    if [[ $fn == /* ]]; then
      loadable_modules+=("$mod")
      covered_modules+=("$mod")
    elif [[ $fn == "(builtin)" ]]; then
      covered_modules+=("$mod")
    fi
  else
    while IFS=$'\t' read -r mod fn; do
      if [[ $fn == /* ]]; then
        loadable_modules+=("$mod")
        covered_modules+=("$mod")
      elif [[ $fn == "(builtin)" ]]; then
        covered_modules+=("$mod")
      fi
    done < <(
      # shellcheck disable=SC2016 # expanded by the inner shell
      arch-chroot "$merged" bash -c '
        kver=$1; shift
        for m in "$@"; do
          f=$(modinfo -k "$kver" -F filename "$m" 2>/dev/null | head -n1 || true)
          printf "%s\t%s\n" "$m" "$f"
        done
      ' _ "$image_kver" "${qcom_modules[@]}"
    )
  fi
  ((${#loadable_modules[@]} > 0)) || { echo "WARNING: no Qualcomm modules resolved in $image_kver; skipping Qualcomm pre-built UKI" >&2; return 1; }

  for fw in "${QUALCOMM_ADRENO_FIRMWARE[@]}"; do
    for dir in /usr/lib/firmware/updates /usr/lib/firmware; do
      for suffix in '' .zst .xz; do
        if [[ -f $merged$dir/$fw$suffix ]]; then
          firmware_files+=("$dir/$fw$suffix")
          recorded_firmware+=("$fw")
          break 2
        fi
      done
    done
  done

  sed -E "s/^MODULES=.*/MODULES=(${loadable_modules[*]})/" \
    "$merged/etc/mkinitcpio-prebuilt-uki.conf" >"$merged/etc/mkinitcpio-prebuilt-uki-qualcomm.conf" || return 1
  if ((${#firmware_files[@]} > 0)); then
    printf 'FILES+=(%s)\n' "${firmware_files[*]}" >>"$merged/etc/mkinitcpio-prebuilt-uki-qualcomm.conf" || return 1
  fi

  install -d "$merged/etc/kernel" || return 1
  printf '[UKI]\nStub=%s\nHWIDs=%s\nDeviceTreeAuto=%s\n' "$stub" "$hwids" "${dtbs[*]}" \
    >"$merged/etc/kernel/uki-prebuilt-qualcomm.conf" || return 1

  echo "Pre-building the Qualcomm Snapdragon UKI (${#loadable_modules[@]} modules, ${#firmware_files[@]} firmware files, ${#dtbs[@]} DTBs)"
  arch-chroot "$merged" mkinitcpio \
    -k "/usr/lib/modules/${image_kver}/vmlinuz" \
    -c /etc/mkinitcpio-prebuilt-uki-qualcomm.conf \
    --cmdline /etc/kernel/cmdline.prebuilt-uki \
    --ukiconfig /etc/kernel/uki-prebuilt-qualcomm.conf \
    -U /var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi \
    -S autodetect 2>&1 | tail -25 || return 1
  [[ -f "$merged/var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi" ]] || return 1

  # Verify ukify embedded .hwids and every .dtbauto section, matching live-uki.sh.
  sections=$(arch-chroot "$merged" ukify inspect /var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi) || return 1
  grep -q '^\.hwids:' <<<"$sections" || { echo "WARNING: Qualcomm pre-built UKI missing .hwids section" >&2; return 1; }
  n_dtb=$(grep -c '^\.dtbauto:' <<<"$sections" || true)
  if (( n_dtb != ${#dtbs[@]} )); then
    echo "WARNING: Qualcomm pre-built UKI has $n_dtb .dtbauto sections, expected ${#dtbs[@]}" >&2
    return 1
  fi

  qualcomm_prebuilt_uki_size_ok "$merged/var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi" || return 1
  install -m 0644 "$merged/var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi" \
    "$out_dir/prebuilt-uki-qualcomm.efi" || return 1
  echo "Pre-built Qualcomm UKI: $(du -h "$out_dir/prebuilt-uki-qualcomm.efi" | cut -f1)"
  printf '%s\n' "${covered_modules[@]}" | sort -u >"$out_dir/prebuilt-uki-qualcomm.modules" || return 1
  if ((${#recorded_firmware[@]} > 0)); then
    printf '%s\n' "${recorded_firmware[@]}" | sort -u >"$out_dir/prebuilt-uki-qualcomm.files" || return 1
  else
    : >"$out_dir/prebuilt-uki-qualcomm.files" || return 1
  fi
  (cd "$root/etc/mkinitcpio.conf.d" 2>/dev/null && printf '%s\n' *.conf | grep -v '^\*\.conf$' | LC_ALL=C sort -u || true) \
    >"$out_dir/prebuilt-uki-qualcomm.dropins" || return 1
  qualcomm_dtb_compatibles "${dtb_paths[@]}" >"$out_dir/prebuilt-uki-qualcomm.compatibles" || return 1
  qualcomm_initramfs_inputs "$root" >"$out_dir/prebuilt-uki-qualcomm.inputs" || return 1
}

build_qualcomm_prebuilt_uki() {
  local out_dir=${1:-$root/var/lib/omarchy-iso}
  local -a qcom_modules
  mapfile -t qcom_modules < <(qualcomm_module_names "$root")
  if ((${#qcom_modules[@]} == 0)); then
    echo "WARNING: no Qualcomm initramfs modules found under $root" >&2
    return 1
  fi
  with_image_overlay build_qualcomm_uki_in "$out_dir"
}

# Build /var/lib/omarchy-iso/prebuilt-uki-n1x.efi from a throwaway overlay of
# $root. Runs while the generic UKI's config and cmdline are still available.
build_n1x_prebuilt_uki() {
  local script=$1 out_dir=${2:-$root/var/lib/omarchy-iso}
  local -a n1x_lines
  mapfile -t n1x_lines < <(n1x_module_lines "$script")
  if ((${#n1x_lines[@]} == 0)); then
    echo "WARNING: $script writes no MODULES lines" >&2
    return 1
  fi
  if [[ ${n1x_overlay_direct:-0} == 1 ]]; then
    _build_n1x_stacked_overlay "$out_dir"
  else
    ( _build_n1x_stacked_overlay "$out_dir" )
  fi
}

pacman_conf="${1:-}"
output="${2:-}"
shift 2 || true
packages=("$@")

if [[ -z $pacman_conf || -z $output || ${#packages[@]} -eq 0 ]]; then
  echo "Usage: build-root-image.sh <pacman.conf> <output.sfs|output.img.zst> <package>..." >&2
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
  local btrfs_threads
  btrfs_threads=$(nproc)
  (( btrfs_threads > 64 )) && btrfs_threads=64
  (( btrfs_threads < 1 )) && btrfs_threads=1
  mount -o "$IMAGE_COMPRESS,noatime,commit=600,thread_pool=$btrfs_threads" "$loop" "$mnt"
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

# Return the smaller of host MemAvailable and remaining container cgroup memory
# in KiB so memory-limited containers do not stage or overlap past their limit.
usable_memory_kb() {
  local host_kb=0 total_kb=0 cgroup_free_kb="" raw cur
  host_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)
  total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)
  (( host_kb > 0 )) || host_kb=$total_kb

  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    read -r raw </sys/fs/cgroup/memory.max 2>/dev/null || raw=""
    if [[ $raw =~ ^[0-9]+$ ]] && (( ${#raw} <= 18 )); then
      cur=0
      [[ -r /sys/fs/cgroup/memory.current ]] && read -r cur </sys/fs/cgroup/memory.current 2>/dev/null || true
      [[ $cur =~ ^[0-9]+$ ]] && (( ${#cur} <= 18 )) || cur=0
      cgroup_free_kb=$(( raw > cur ? (raw - cur) / 1024 : 0 ))
    fi
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    read -r raw </sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || raw=""
    if [[ $raw =~ ^[0-9]+$ ]] && (( ${#raw} <= 18 )) && (( total_kb == 0 || raw / 1024 < total_kb )); then
      cur=0
      [[ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]] && read -r cur </sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || true
      [[ $cur =~ ^[0-9]+$ ]] && (( ${#cur} <= 18 )) || cur=0
      cgroup_free_kb=$(( raw > cur ? (raw - cur) / 1024 : 0 ))
    fi
  fi

  if [[ -n $cgroup_free_kb ]] && (( host_kb == 0 || cgroup_free_kb < host_kb )); then
    printf '%s\n' "$cgroup_free_kb"
  else
    printf '%s\n' "$host_kb"
  fi
}

hardware_layer_pids=()
hardware_layer_names=()
hardware_layer_logs=()
prebuilt_pids=()
try_layer_pid=""
cleanup() {
  local status=$? pid
  set +e
  for pid in "${prebuilt_pids[@]}" "${hardware_layer_pids[@]}"; do
    [[ -n $pid ]] || continue
    stop_pid_tree "$pid"
  done
  if [[ -n $try_layer_pid ]]; then
    stop_pid_tree "$try_layer_pid"
  fi
  if (( ${#prebuilt_pids[@]} > 0 || ${#hardware_layer_pids[@]} > 0 )) || [[ -n $try_layer_pid ]]; then
    wait "${prebuilt_pids[@]}" "${hardware_layer_pids[@]}" ${try_layer_pid:+"$try_layer_pid"} 2>/dev/null || true
  fi
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
trap 'exit 143' TERM INT

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
  mem_avail_kb=$(usable_memory_kb)
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

if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
  btrfs filesystem sync "$mnt"
fi

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

# shellcheck disable=SC2010 # kernel version directories, named by pacman
image_kver=$(ls -1 "$root/usr/lib/modules/" | grep -E '^[0-9]+\.' | head -1)
# The output directory persists between builds: no layer from an older one.
rm -f "${output%/*}"/omarchy-layer.*.tar.zst
if [[ -z $image_kver ]]; then
  echo "WARNING: no kernel version found under /usr/lib/modules/; skipping the UKI pre-build"
else
  # The kernel package this image carries: linux-omarchy since upstream made it
  # the default, stock linux before. The installer names the UKI
  # and its Limine entry after it, and with or without a pre-built UKI boots a
  # selected kernel other than this one first.
  image_kernel=$(<"$root/usr/lib/modules/${image_kver}/pkgbase")
  echo "$image_kernel" >"$root/var/lib/omarchy-iso/prebuilt-uki.kernel"

  # Omarchy's boot splash (omarchy-settings' omarchy-splash hook) runs only in
  # a busybox initramfs, and these UKIs' are systemd ones, with Plymouth. An
  # image with the splash gets no generic, Snapdragon or N1x UKI here, only
  # the N1x layer: each install builds its own, so the splash is there from
  # the first boot.
  prebuilt_ukis=1
  if [[ -f $root/etc/initcpio/install/omarchy-splash ]]; then
    prebuilt_ukis=0
    echo "No pre-built UKI: the image draws the unlock prompt with omarchy-splash"
  fi

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
  # shellcheck source=/dev/null # the image's own vconsole.conf
  ( [ -f "$root/etc/vconsole.conf" ] && . "$root/etc/vconsole.conf"; printf '%s\n' "${KEYMAP:-}" ) \
    >"$root/var/lib/omarchy-iso/prebuilt-uki.keymap"

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

  # Once the staging tree is ready, pre-built UKIs, hardware layers,
  # Try layers, and the parallel btrfs copy are all independent read-only
  # consumers of $root. Stage the four temporary UKI build files outside $root
  # and remove them from $root before mounting any overlay so $root stays
  # strictly read-only while every overlay and copy-tree-parallel.py overlap.
  stage_async=0
  prebuilt_async=0
  stage_mem_avail_kb=$(usable_memory_kb)
  if [[ ${OMARCHY_FAST_COMPRESSION:-} != 1 ]]; then
    if (( stage_mem_avail_kb >= 12 * 1024 * 1024 )); then
      stage_async=1
    fi
    # Require >= 16 GiB free on top of $stage + mirror recompression before
    # launching concurrent UKI/N1x overlays so 32 GiB runners never
    # approach OOM, while 64 GiB hosts overlap the full ~210 s UKI chain.
    if (( stage_mem_avail_kb >= 16 * 1024 * 1024 )); then
      prebuilt_async=1
    fi
  elif (( stage_mem_avail_kb >= 6 * 1024 * 1024 )); then
    prebuilt_async=1
  fi

  uki_tmp=""
  prebuilt_out="$work/prebuilt-out"
  generic_uki_pid=""
  qcom_uki_pid=""
  n1x_uki_pid=""
  generic_uki_log="$work/prebuilt-uki.log"
  qcom_uki_log="$work/prebuilt-uki-qualcomm.log"
  n1x_uki_log="$work/prebuilt-uki-n1x.log"
  if (( prebuilt_async )); then
    uki_tmp="$work/uki-tmp"
    mkdir -p "$uki_tmp" "$prebuilt_out"
    cp -p "$root/usr/lib/initcpio/install/omarchy-vconsole-room" "$uki_tmp/omarchy-vconsole-room"
    cp -p "$root/etc/vconsole.conf.prebuilt-uki" "$uki_tmp/vconsole.conf.prebuilt-uki"
    cp -p "$root/etc/mkinitcpio-prebuilt-uki.conf" "$uki_tmp/mkinitcpio-prebuilt-uki.conf"
    cp -p "$root/etc/kernel/cmdline.prebuilt-uki" "$uki_tmp/cmdline.prebuilt-uki"
    rm -f "$root/etc/mkinitcpio-prebuilt-uki.conf" "$root/etc/kernel/cmdline.prebuilt-uki" \
      "$root/etc/vconsole.conf.prebuilt-uki" "$root/usr/lib/initcpio/install/omarchy-vconsole-room" \
      "$root/var/lib/omarchy-iso/prebuilt-uki.efi" \
      "$root/var/lib/omarchy-iso/prebuilt-uki-qualcomm".{efi,modules,files,dropins,compatibles,inputs} \
      "$root/var/lib/omarchy-iso/prebuilt-uki-n1x".{efi,modules}
    if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
      btrfs filesystem sync "$mnt"
    fi
    if [[ -n ${OMARCHY_SNAPDRAGON:-} ]]; then
      if [[ $(uname -m) == aarch64 ]] && (( prebuilt_ukis )); then
        build_qualcomm_prebuilt_uki "$prebuilt_out" >"$qcom_uki_log" 2>&1 &
        qcom_uki_pid=$!
        prebuilt_pids+=("$qcom_uki_pid")
      fi
    else
      if (( prebuilt_ukis )); then
        with_image_overlay build_generic_uki_in "$prebuilt_out" >"$generic_uki_log" 2>&1 &
        generic_uki_pid=$!
        prebuilt_pids+=("$generic_uki_pid")
      fi
      n1x_script="$root/usr/share/omarchy/install/hardware/n1x.sh"
      if [[ $(uname -m) == aarch64 && -f $n1x_script ]]; then
        n1x_overlay_direct=1 build_n1x_prebuilt_uki "$n1x_script" "$prebuilt_out" >"$n1x_uki_log" 2>&1 &
        n1x_uki_pid=$!
        prebuilt_pids+=("$n1x_uki_pid")
      fi
    fi
  fi

  if [[ -n ${OMARCHY_SNAPDRAGON:-} ]]; then
    if (( ! ${prebuilt_async:-0} && prebuilt_ukis )); then
      # A Snapdragon ISO installs only Snapdragon laptops, so skip the generic
      # UKI and pre-build the Snapdragon UKI (all Snapdragon DTBs via
      # DeviceTreeAuto + HWIDs + shared Qualcomm early modules + Adreno microcode)
      # so standard Snapdragon installs copy it in place instead of spending ~7s
      # running mkinitcpio + ukify on the target.
      rm -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi" \
        "$root/var/lib/omarchy-iso/prebuilt-uki-qualcomm".{efi,modules,files,dropins,compatibles,inputs}
      if [[ $(uname -m) == aarch64 ]] && ! build_qualcomm_prebuilt_uki; then
        echo "WARNING: no Qualcomm pre-built UKI; Snapdragon installs will build their own"
        rm -f "$root/var/lib/omarchy-iso/prebuilt-uki-qualcomm".{efi,modules,files,dropins,compatibles,inputs}
      fi
    fi
  else
    if (( ! ${prebuilt_async:-0} && prebuilt_ukis )); then
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
  fi
  # N1x: its layer, and a second pre-built UKI where the image has the first.
  # Its hardware setup always adds the same early-loading modules, the NVIDIA
  # stack for early KMS and the I2C keyboard for the LUKS prompt, so the
  # generic UKI never fits it and every N1x built its own at install, about
  # 20s. This one is built with them, read from the image's own n1x.sh so the
  # two cannot drift, and recorded the same way; the installer copies it where
  # the machine's lines match (_n1x_prebuilt_uki).
  # The NVIDIA packages go into a throwaway overlay of the image, never into
  # the image itself. What they add is packed from that overlay as the N1x
  # layer, which the installer extracts on an N1x, so the driver in the UKI is
  # the one on disk.
  n1x_script="$root/usr/share/omarchy/install/hardware/n1x.sh"
  if (( ! prebuilt_async )) && [[ $(uname -m) == aarch64 && -z ${OMARCHY_SNAPDRAGON:-} && -f $n1x_script ]] &&
    { (( ! prebuilt_ukis )) || [[ -f "$root/var/lib/omarchy-iso/prebuilt-uki.efi" ]]; }; then
    build_n1x_prebuilt_uki "$n1x_script" || {
      echo "WARNING: no N1x pre-built UKI or layer; N1x installs build their own and pacstrap the NVIDIA stack"
      rm -f "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.efi" "$root/var/lib/omarchy-iso/prebuilt-uki-n1x.modules" \
        "$(layer_path aarch64-n1x)"
    }
  fi

  # Only this build uses these; the installed system has no use for them.
  if (( ! prebuilt_async )); then
    rm -f "$root/etc/mkinitcpio-prebuilt-uki.conf" "$root/etc/kernel/cmdline.prebuilt-uki" \
      "$root/etc/vconsole.conf.prebuilt-uki" "$root/usr/lib/initcpio/install/omarchy-vconsole-room"
  fi
fi

# When $image_kver was empty, still decide whether read-only stage consumers
# can overlap with the parallel btrfs copy.
if [[ -z $image_kver ]]; then
  stage_async=0
  prebuilt_async=0
  if [[ ${OMARCHY_FAST_COMPRESSION:-} != 1 ]]; then
    stage_mem_avail_kb=$(usable_memory_kb)
    if (( stage_mem_avail_kb >= 12 * 1024 * 1024 )); then
      stage_async=1
    fi
  fi
fi

# Hardware layers, now that the image's tree is final: each is the difference
# its packages make to the image as it ships.
if [[ -n $image_kver ]]; then
  hardware_layers_async=$(( stage_async || prebuilt_async ))
  build_hardware_layers
fi

# The Try layer is built against the finished image, before copying into the
# compressed btrfs filesystem: it only reads the image, through an overlay whose
# upper directory it keeps. Pass effective_pacman_conf so deferred boot hooks
# (mkinitcpio/Limine) stay masked when pacstrap installs Try packages.
try_layer_log="$work/try-layer.log"
if [[ -n ${OMARCHY_TRY_LAYER:-} ]]; then
  if (( stage_async || prebuilt_async )); then
    bash /builder/build-try-layer.sh "$root" "$OMARCHY_TRY_LAYER" "${OMARCHY_TRY_CHANNEL:-stable}" "$effective_pacman_conf" >"$try_layer_log" 2>&1 &
    try_layer_pid=$!
  else
    bash /builder/build-try-layer.sh "$root" "$OMARCHY_TRY_LAYER" "${OMARCHY_TRY_CHANNEL:-stable}" "$effective_pacman_conf"
  fi
fi

join_stage_consumers() {
  local i hw_status try_status
  for i in "${!hardware_layer_pids[@]}"; do
    hw_status=0
    wait "${hardware_layer_pids[i]}" || hw_status=$?
    [[ -f ${hardware_layer_logs[i]} ]] && cat "${hardware_layer_logs[i]}"
    rm -f "${hardware_layer_logs[i]}"
    if (( hw_status != 0 )); then
      echo "WARNING: no ${hardware_layer_names[i]} layer; those machines install its packages at install time"
      rm -f "$(layer_path "${hardware_layer_names[i]}")"
    fi
  done
  hardware_layer_pids=()

  if [[ -n $try_layer_pid ]]; then
    try_status=0
    wait "$try_layer_pid" || try_status=$?
    try_layer_pid=""
    [[ -f $try_layer_log ]] && cat "$try_layer_log"
    rm -f "$try_layer_log"
    (( try_status == 0 )) || exit "$try_status"
  fi
}

join_prebuilt_boot_images() {
  local target_root=$1
  local qcom_status=0 generic_status=0 n1x_status=0
  local f pid copy_rc=0
  local -a copy_pids=()
  (( prebuilt_async )) || return 0

  if [[ -n $qcom_uki_pid ]]; then
    wait "$qcom_uki_pid" || qcom_status=$?
    [[ -f $qcom_uki_log ]] && cat "$qcom_uki_log"
    rm -f "$qcom_uki_log"
    if (( qcom_status != 0 )); then
      echo "WARNING: no Qualcomm pre-built UKI; Snapdragon installs will build their own"
      rm -f "$prebuilt_out/prebuilt-uki-qualcomm".{efi,modules,files,dropins,compatibles,inputs}
    fi
  fi

  if [[ -n $generic_uki_pid ]]; then
    wait "$generic_uki_pid" || generic_status=$?
    [[ -f $generic_uki_log ]] && cat "$generic_uki_log"
    rm -f "$generic_uki_log"
    if (( generic_status == 2 )); then
      exit 1
    elif (( generic_status != 0 )); then
      rm -f "$prebuilt_out/prebuilt-uki.efi"
    fi
  fi

  if [[ -n $n1x_uki_pid ]]; then
    wait "$n1x_uki_pid" || n1x_status=$?
    [[ -f $n1x_uki_log ]] && cat "$n1x_uki_log"
    rm -f "$n1x_uki_log"
    if (( prebuilt_ukis )) && [[ ! -f $prebuilt_out/prebuilt-uki.efi ]]; then
      rm -f "$prebuilt_out/prebuilt-uki-n1x.efi" "$prebuilt_out/prebuilt-uki-n1x.modules" \
        "$(layer_path aarch64-n1x)"
    elif (( n1x_status != 0 )); then
      echo "WARNING: no N1x pre-built UKI or layer; N1x installs build their own and pacstrap the NVIDIA stack"
      rm -f "$prebuilt_out/prebuilt-uki-n1x.efi" "$prebuilt_out/prebuilt-uki-n1x.modules" \
        "$(layer_path aarch64-n1x)"
    fi
  fi

  prebuilt_pids=()

  # Copy the finished prebuilt boot artifacts into the btrfs image in parallel
  # so btrfs compresses all of them concurrently before syncing.
  for f in "$prebuilt_out"/*; do
    [[ -f $f ]] || continue
    cp -p "$f" "$target_root/var/lib/omarchy-iso/${f##*/}" &
    copy_pids+=($!)
  done
  for pid in "${copy_pids[@]}"; do
    wait "$pid" || copy_rc=1
  done
  (( copy_rc == 0 )) || exit 1
  btrfs filesystem sync "$mnt"
}

if [[ ${OMARCHY_FAST_COMPRESSION:-} != 1 ]]; then
  # Now create the compressed btrfs filesystem and populate it in parallel across
  # every CPU so zstd:15 runs at full host parallelism, then join all read-only
  # consumers and free the staging tree before shrinking and packing.
  mount_root_btrfs

  echo "Populating btrfs root image with $IMAGE_COMPRESS across $(nproc) CPUs"
  copy_start=$(date +%s)
  python3 "$(dirname -- "${BASH_SOURCE[0]}")/copy-tree-parallel.py" "$stage" "$mnt/$IMAGE_SUBVOLUME"
  btrfs filesystem sync "$mnt"
  echo "Populated btrfs root image in $(( $(date +%s) - copy_start ))s"

  join_prebuilt_boot_images "$mnt/$IMAGE_SUBVOLUME"
  join_stage_consumers

  if mountpoint -q "$stage" 2>/dev/null; then
    umount -R "$stage"
  fi
  rm -rf "$stage"
else
  # Under --fast, $mnt/$IMAGE_SUBVOLUME is the lowerdir of all overlays, so
  # join Try and hardware layers before writing prebuilt artifacts into it.
  join_stage_consumers
  join_prebuilt_boot_images "$mnt/$IMAGE_SUBVOLUME"
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
btrfs filesystem sync "$mnt"
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
if [[ $output == *.sfs ]]; then
  # A squashfs holding the raw image, so the kernel can mount it: Try Omarchy
  # boots it from the medium, read as it is used. The installer does not
  # mount it: omarchy-image-write write-squashfs reads its blocks straight
  # from the file and decodes them with libzstd, 1.06-1.14 s for the
  # 2026-10-25 image on an i5-12600K with it cached, against 0.98 s for the
  # zstd frames below and 1.72-1.79 s read through a threads=multi mount.
  # 3,944,173,568 bytes, 20 MB under the frames, in 2 s; 128 KiB random reads
  # 1.1 ms p50 mounted (EROFS zstd: 1.6 ms, and 2.4 s for the full read
  # file-backed; EROFS LZ4HC: 29 s). zstd at level 19: the files inside are
  # btrfs-compressed already, so 19 saves only 20 MB over 3, but costs
  # nothing where it counts (the write took 1.00 s against 1.08 s; 50 s more
  # to build). No fragments, so the image's tail is a block write-squashfs
  # can place; no xattrs: the file inside has none.
  #
  # 256 KiB blocks, because Try reads the image as btrfs asks for it, about
  # 66 KB at a time, and squashfs decompresses a whole block for each read.
  # To reach Try's desktop in QEMU, 1 MiB blocks read 723 MB off the medium
  # for 388 MB that btrfs wanted (1.86x); 256 KiB blocks read 576 MB (1.42x),
  # three runs each. That costs 17 MB of squashfs and 0.33 s more decoding
  # for the install on 4 CPUs (3.30 s against 2.97 s, the same image
  # written); 128 KiB saves only 12 MB more of the read.
  echo "Packing the root image into a squashfs"
  sfs_zstd_level=19
  [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]] && sfs_zstd_level=1
  mkdir -p "$work/sfs"
  ln "$backing" "$work/sfs/omarchy-root.img"
  mksquashfs "$work/sfs" "$output" -comp zstd -Xcompression-level "$sfs_zstd_level" -b 256K -no-fragments -noappend -no-xattrs -quiet
  rm -f "$work/sfs/omarchy-root.img"
else
  echo "Packing the root image as 256 KiB zstd frames"
  omarchy-image-write pack "$backing" "$output"
fi
echo "Root image: $(du -h "$output" | cut -f1) at $output (from ${shrink_mb}M apparent input)"
