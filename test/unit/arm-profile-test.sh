#!/bin/bash
#
# Unit tests for builder/architecture.sh and configs/profiledef.sh: the
# variables each architecture selects, the releng/profile rewrite for aarch64,
# and that x86_64 is left exactly as it was.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export BUILDER_ROOT="$ROOT/builder"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# profiledef.sh uses GNU date's --date=@EPOCH. On a BSD host (macOS) shim just
# that form so the profile can be sourced here too.
mkdir -p "$work/shim"
if ! date --date=@0 +%Y >/dev/null 2>&1; then
  cat >"$work/shim/date" <<'SHIM'
#!/bin/bash
epoch=${1#--date=@}
exec python3 -c 'import sys, time; print(time.strftime(sys.argv[2].lstrip("+"), time.gmtime(int(sys.argv[1]))))' "$epoch" "$2"
SHIM
  chmod +x "$work/shim/date"
fi
export PATH="$work/shim:$PATH"

# ---------------------------------------------------------------- selection

arm_selection=$(
  export OMARCHY_ARCH=aarch64 OMARCHY_MIRROR=stable OMARCHY_SETTINGS_PACKAGE=omarchy-settings
  source "$ROOT/builder/architecture.sh"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$OMARCHY_MEDIA_TARGET" "$OMARCHY_PLATFORM" "$OMARCHY_BOOT_BACKEND" \
    "$DISTRO_KEYRING_PACKAGE" "$DISTRO_KEYRING_NAME" "$NODE_DIST_ARCH" \
    "$PROFILE_PACKAGES" "$PACMAN_ONLINE_CONFIG" \
    "$LIVE_KERNEL/$LIVE_KERNEL_BOOT_NAME/$LIVE_INITRAMFS_BOOT_NAME" "${MKARCHISO[*]}"
  printf '%s\n' "${LIVE_PACKAGES[*]}" "${BUILD_HOST_PACKAGES[*]}"
)
[[ $(sed -n 1p <<<"$arm_selection") == \
  "aarch64/generic|generic|limine|archlinuxarm-keyring|archlinuxarm|arm64|packages.aarch64|/configs/pacman-online-arm.conf|linux-aarch64/Image/initramfs-linux.img|/tmp/omarchy-mkarchiso-aarch64" ]] ||
  fail "aarch64 selects the ALARM keyring, arm64 Node, packages.aarch64 and the patched mkarchiso" "$arm_selection"
live=$(sed -n 2p <<<"$arm_selection")
[[ " $live " == *" linux-aarch64 "* && " $live " != *" linux-t2 "* && " $live " != *" ttfx "* ]] ||
  fail "aarch64 live packages boot linux-aarch64 without ttfx" "$live"
host=$(sed -n 3p <<<"$arm_selection")
[[ " $host " != *" archiso "* && " $host " == *" squashfs-tools "* ]] ||
  fail "aarch64 build host installs mkarchiso's dependencies, not the archiso package" "$host"
pass "aarch64 selection"

x86_selection=$(
  export OMARCHY_ARCH=x86_64 OMARCHY_MIRROR=edge OMARCHY_SETTINGS_PACKAGE=omarchy-settings-dev
  source "$ROOT/builder/architecture.sh"
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$OMARCHY_MEDIA_TARGET" "$DISTRO_KEYRING_PACKAGE" "$NODE_DIST_ARCH" \
    "$PROFILE_PACKAGES" "$PACMAN_ONLINE_CONFIG" "$LIVE_KERNEL" "${MKARCHISO[*]}"
  printf '%s\n' "${LIVE_PACKAGES[*]}" "${BUILD_HOST_PACKAGES[*]}"
)
[[ $(sed -n 1p <<<"$x86_selection") == \
  "x86_64/pc|archlinux-keyring|x64|packages.x86_64|/configs/pacman-online-edge.conf|linux-t2|mkarchiso" ]] ||
  fail "x86_64 selection is unchanged" "$x86_selection"
[[ $(sed -n 2p <<<"$x86_selection") == \
  "linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring omarchy-settings-dev lvm2 cryptsetup parted" ]] ||
  fail "x86_64 live packages are unchanged" "$x86_selection"
[[ $(sed -n 3p <<<"$x86_selection") == \
  "archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli" ]] ||
  fail "x86_64 build host packages are unchanged" "$x86_selection"
pass "x86_64 selection is the pre-existing build"

default_arch=$(
  unset OMARCHY_ARCH OMARCHY_MEDIA_TARGET
  source "$ROOT/builder/architecture.sh"
  printf '%s|%s\n' "$OMARCHY_ARCH" "$OMARCHY_MEDIA_TARGET"
)
[[ $default_arch == "x86_64|x86_64/pc" ]] || fail "default is x86_64/pc" "$default_arch"
pass "architecture defaults to x86_64"

for bad in "aarch64:aarch64/apple-silicon" "x86_64:aarch64/generic" "riscv64:"; do
  if (
    export OMARCHY_ARCH=${bad%%:*} OMARCHY_MEDIA_TARGET=${bad#*:}
    source "$ROOT/builder/architecture.sh"
  ) 2>/dev/null; then
    fail "architecture.sh rejects $bad"
  fi
done
pass "unsupported architecture/target pairs are rejected"

# ----------------------------------------------------------- package lists

filtered=$(
  export OMARCHY_ARCH=aarch64 OMARCHY_MIRROR=stable OMARCHY_SETTINGS_PACKAGE=omarchy-settings
  source "$ROOT/builder/architecture.sh"
  printf '%s\n' linux linux-headers amd-ucode intel-ucode tzupdate base limine | filter_target_packages
)
[[ $filtered == $'linux-aarch64\nlinux-aarch64-headers\nbase\nlimine' ]] ||
  fail "aarch64 drops microcode and tzupdate and renames the kernel" "$filtered"

x86_filtered=$(
  export OMARCHY_ARCH=x86_64 OMARCHY_MIRROR=stable OMARCHY_SETTINGS_PACKAGE=omarchy-settings
  source "$ROOT/builder/architecture.sh"
  printf '%s\n' linux linux-headers amd-ucode intel-ucode tzupdate | filter_target_packages
)
[[ $x86_filtered == $'linux\nlinux-headers\namd-ucode\nintel-ucode\ntzupdate' ]] ||
  fail "x86_64 package lists pass through untouched" "$x86_filtered"
pass "target package list filtering"

# -------------------------------------------------------------- profile

make_profile() {
  local profile=$1

  mkdir -p \
    "$profile/airootfs/etc/mkinitcpio.d" \
    "$profile/airootfs/etc/mkinitcpio.conf.d" \
    "$profile/grub"
  printf '%s\n' linux broadcom-wl memtest86+ intel-ucode syslinux edk2-shell base linux-firmware >"$profile/packages.x86_64"
  printf '%s\n' \
    'HOOKS=(base udev microcode modconf kms memdisk archiso plymouth block filesystems keyboard)' \
    >"$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  touch \
    "$profile/airootfs/etc/mkinitcpio.d/linux.preset" \
    "$profile/airootfs/etc/mkinitcpio.d/linux-t2.preset"
  cp "$ROOT/configs/grub/grub.cfg" "$profile/grub/grub.cfg"
  cp "$ROOT/configs/grub/loopback.cfg" "$profile/grub/loopback.cfg"
  cp "$ROOT/configs/pacman-offline.conf" "$profile/pacman-offline.conf"
}

profile="$work/arm-profile"
make_profile "$profile"
(
  export OMARCHY_ARCH=aarch64 OMARCHY_MIRROR=stable OMARCHY_SETTINGS_PACKAGE=omarchy-settings
  source "$ROOT/builder/architecture.sh"
  prepare_media_profile "$profile"
)
[[ -f $profile/packages.aarch64 && ! -e $profile/packages.x86_64 ]] ||
  fail "releng's packages.x86_64 becomes packages.aarch64"
[[ $(cat "$profile/packages.aarch64") == $'base\nlinux-firmware' ]] ||
  fail "x86-only releng packages are pruned" "$(cat "$profile/packages.aarch64")"
[[ ! -e $profile/airootfs/etc/mkinitcpio.d/linux.preset && ! -e $profile/airootfs/etc/mkinitcpio.d/linux-t2.preset ]] ||
  fail "the x86 kernel presets are removed"
# ALARM's linux-aarch64 ships its own preset; a copy in airootfs would make
# pacstrap fail on a conflicting file. Its default-config build must still
# come out with archiso's hooks, so a drop-in that sorts last re-asserts them.
[[ ! -e $profile/airootfs/etc/mkinitcpio.d/linux-aarch64.preset ]] ||
  fail "no preset is shipped for the linux-aarch64 package"
live_conf="$profile/airootfs/etc/mkinitcpio.conf.d/zz-archiso-live.conf"
[[ -f $live_conf ]] || fail "a last-sorting drop-in re-asserts archiso's config"
grep -q '^HOOKS=(.* archiso .*)' "$live_conf" || fail "the live drop-in carries the archiso hooks" "$(cat "$live_conf")"
grep -q ' microcode \| memdisk ' "$live_conf" && fail "the live drop-in has no x86 hooks" "$(cat "$live_conf")"
grep -Fxq 'MODULES=()' "$live_conf" || fail "the live drop-in resets forced modules" "$(cat "$live_conf")"
grep -Fxq 'HOOKS=(base udev modconf kms archiso plymouth block filesystems keyboard)' \
  "$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf" ||
  fail "microcode and memdisk hooks are dropped" "$(cat "$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf")"
for cfg in grub.cfg loopback.cfg; do
  grep -q 'linux /%INSTALL_DIR%/boot/%ARCH%/Image ' "$profile/grub/$cfg" ||
    fail "$cfg boots ALARM's kernel" "$(grep -n 'linux /' "$profile/grub/$cfg")"
  grep -q 'initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img' "$profile/grub/$cfg" ||
    fail "$cfg loads ALARM's initramfs" "$(grep -n 'initrd ' "$profile/grub/$cfg")"
  ! grep -q 'linux-t2' "$profile/grub/$cfg" || fail "$cfg no longer mentions linux-t2"
done
pass "aarch64 profile rewrite"

x86_profile="$work/x86-profile"
make_profile "$x86_profile"
cp -R "$x86_profile" "$work/x86-before"
(
  export OMARCHY_ARCH=x86_64 OMARCHY_MIRROR=stable OMARCHY_SETTINGS_PACKAGE=omarchy-settings
  source "$ROOT/builder/architecture.sh"
  prepare_media_profile "$x86_profile"
  prepare_mkarchiso
)
diff -r "$work/x86-before" "$x86_profile" >/dev/null || fail "x86_64 profile is untouched" "$(diff -r "$work/x86-before" "$x86_profile")"
pass "x86_64 profile is untouched"

# ------------------------------------------------------------- mkarchiso

patch=$ROOT/builder/archiso-aarch64.patch
grep -Fq 'kernel_images=("${pacstrap_dir}/boot/Image")' "$patch" || fail "patch copies /boot/Image as the kernel"
grep -Fq 'efiboot_files+=("${work_dir}/BOOT${uefi_arch[$arch]}.EFI")' "$patch" || fail "patch makes edk2-shell optional"
grep -Fq 'required_grubmodules=(configfile iso9660 linux normal search search_fs_uuid)' "$patch" ||
  fail "patch keeps the GRUB modules the ISO cannot boot without"
if [[ -f $ROOT/archiso/archiso/mkarchiso ]]; then
  cp "$ROOT/archiso/archiso/mkarchiso" "$work/mkarchiso"
  patch --forward --silent "$work/mkarchiso" "$patch" || fail "patch applies to the pinned archiso"
  pass "archiso-aarch64.patch applies to the archiso submodule"
else
  pass "archiso-aarch64.patch is intact (submodule not checked out, apply skipped)"
fi
grep -Fq 'prepare_mkarchiso' "$ROOT/builder/build-iso.sh" || fail "build-iso.sh prepares mkarchiso"
grep -Fq '"${MKARCHISO[@]}" -v -w' "$ROOT/builder/build-iso.sh" || fail "build-iso.sh runs the selected mkarchiso"

# ------------------------------------------------------------ profiledef

profile_values() {
  (
    export OMARCHY_ARCH=$1 SOURCE_DATE_EPOCH=0
    declare -A file_permissions=()
    source "$ROOT/configs/profiledef.sh"
    printf '%s|%s|%s\n' "$arch" "${bootmodes[*]}" "${airootfs_image_tool_options[*]}"
  )
}
arm_values=$(profile_values aarch64)
[[ $arm_values == "aarch64|uefi.grub|-comp xz "* && $arm_values != *zstd* ]] ||
  fail "aarch64 profile is UEFI-only with an xz squashfs" "$arm_values"
x86_values=$(profile_values x86_64)
[[ $x86_values == "x86_64|bios.syslinux uefi.grub|-comp zstd -Xcompression-level 19 -b 1M -action uncompressed@subpathname(var/cache/omarchy/mirror/offline)" ]] ||
  fail "x86_64 profile is unchanged" "$x86_values"
unset_values=$(
  unset OMARCHY_ARCH
  profile_values "" 2>/dev/null || true
)
[[ $unset_values == "x86_64|"* ]] || fail "profiledef defaults to x86_64 without OMARCHY_ARCH" "$unset_values"
pass "profiledef per-arch bootmodes and squashfs compression"

# ------------------------------------------------------------ pacman conf

arm_conf=$ROOT/configs/pacman-online-arm.conf
grep -Fxq 'Architecture = aarch64' "$arm_conf" || fail "ARM pacman config pins aarch64"
for repo in core extra alarm aur omarchy; do
  grep -Fxq "[$repo]" "$arm_conf" || fail "ARM pacman config has [$repo]"
done
! grep -v '^#' "$arm_conf" | grep -q 'arch-mact2\|file://' || fail "ARM pacman config has no T2 or local repos"
pass "ARM pacman config"
