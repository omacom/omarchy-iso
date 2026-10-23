#!/bin/bash
#
# Static checks for the aarch64 / N1x build overlay. These run without Docker
# and guard the pieces that a wrong edit would silently break: the entrypoint's
# argument contract, the GRUB templating markers, the arm64 archiso patch
# still applying to the pinned submodule, and the manifest filter.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture" /tmp/omarchy-aarch64-base.packages' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The arm64 archiso patches are checked against the pinned submodule. A
# checkout without it skips those checks; CI fetches it, so there a missing
# submodule fails rather than passing checks that never ran.
have_archiso() {
  [[ -f "$ROOT/archiso/archiso/mkarchiso" ]] && return 0
  [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} ]] && fail "the archiso submodule is not checked out, so the arm64 patches go unchecked"
  echo "skip: the archiso submodule is not checked out, so the arm64 patches go unchecked" >&2
  return 1
}

# --- entrypoint argument contract -------------------------------------------
bash -n "$ROOT/bin/omarchy-iso-make" "$ROOT/builder/build-iso.sh" \
  "$ROOT/builder/aarch64-package-filter.sh" "$ROOT/builder/grub-platform.sh" \
  "$ROOT/builder/archiso-aarch64-mkinitcpio.sh" "$ROOT/builder/archiso-aarch64-grub-modules.sh" \
  "$ROOT/builder/node-release.sh" "$ROOT/builder/arm64-kernel-image.sh" \
  "$ROOT/builder/n1x-dev-ssh/omarchy-n1x-dev-ssh" "$ROOT/configs/airootfs/root/.automated_script.sh"

grep -Eq '^ *CONTAINER_IMAGE=ghcr\.io/menci/archlinuxarm@sha256:[0-9a-f]{64}$' "$ROOT/bin/omarchy-iso-make" || fail "aarch64 container is not pinned by digest on ghcr.io"
grep -Eq 'requires? (--package-dir DIR|the package bundle)' "$ROOT/bin/omarchy-iso-make" "$ROOT/builder/build-iso.sh" \
  && fail "an aarch64 build still requires a package bundle, though edge publishes linux-omarchy"
grep -Fq 'ships no $required' "$ROOT/builder/build-iso.sh" || fail "a runtime without the platform support is not refused"
for required in bin/omarchy-hw-platform install/hardware/qualcomm/dtb-uki.sh install/omarchy-aarch64-qualcomm.packages \
  install/omarchy-aarch64-n1x.packages install/omarchy-aarch64-gb10.packages; do
  sed -n '/^  for required in /,/; do$/p' "$ROOT/builder/build-iso.sh" | grep -Fq -- "$required" \
    || fail "a runtime without $required is not refused"
done
grep -Fq 'sha256sum --check --strict --quiet SHA256SUMS' "$ROOT/bin/omarchy-iso-make" || fail "bundle checksums are not verified on the host"
grep -Fq -- '-v "$PACKAGE_DIR:/packages:ro"' "$ROOT/bin/omarchy-iso-make" || fail "bundle is not mounted read-only at /packages"
grep -Fq 'OMARCHY_ARCH == x86_64 && -d /var/cache/pacman/pkg' "$ROOT/bin/omarchy-iso-make" || fail "host pacman cache would leak into aarch64 builds"
grep -Fq 'aarch64 builds use the stable, rc or edge channel' "$ROOT/builder/build-iso.sh" || fail "an aarch64 build accepts a channel it has no config for"
grep -Fq 'OMARCHY_KERNEL=linux-omarchy' "$ROOT/bin/omarchy-iso-make" || fail "an aarch64 image does not boot linux-omarchy"
grep -Fq -- '--kernel' "$ROOT/bin/omarchy-iso-make" && fail "an aarch64 build still offers a choice of kernel"
grep -Fq 'OMARCHY_ARM_PLATFORM' "$ROOT/bin/omarchy-iso-make" "$ROOT/builder/build-iso.sh" && fail "an aarch64 build still asks which board it is for"
grep -Fq "ALL_kver='/boot/vmlinuz-linux-omarchy'" "$ROOT/builder/linux-omarchy.preset" || fail "the live preset does not boot linux-omarchy"
grep -Fq 'echo "$OMARCHY_KERNEL" > "$build_cache_dir/airootfs/root/omarchy_kernel"' "$ROOT/builder/build-iso.sh" || fail "the installer is not told which kernel to install"

# --- builder wiring -----------------------------------------------------------
grep -Fq 'online_pacman_conf="/configs/pacman-online-aarch64-${OMARCHY_MIRROR}.conf"' "$ROOT/builder/build-iso.sh" || fail "aarch64 does not use its own online pacman config for the channel"
if grep -Fq -- '--config "/configs/pacman-online-' "$ROOT/builder/build-iso.sh"; then
  fail "a pacman call still hardcodes the x86 mirror config"
fi
grep -Fq 'configure_archiso_aarch64_mkinitcpio' "$ROOT/builder/build-iso.sh" || fail "live initramfs is not adapted for aarch64"
grep -Fq 'kernel_options="console=tty0 acpi=nospcr initramfs_async=0"' "$ROOT/builder/build-iso.sh" || fail "aarch64 live boot does not pin the panel console"
grep -Fq 'boot_splash_kernel_options="quiet splash "' "$ROOT/builder/build-iso.sh" || fail "aarch64 live boot does not show the splash"
grep -Fq 'plymouth.enable=0 console=tty0' "$ROOT/builder/build-iso.sh" && fail "aarch64 live boot still turns Plymouth off"
grep -Fq '"$mkarchiso_command" -v -w' "$ROOT/builder/build-iso.sh" || fail "builder does not use the patched mkarchiso on aarch64"
# pacman takes the first repository carrying a name: the platform bundle, then
# Omarchy's aarch64 repo, then Arch Linux ARM. Each channel's config is edge's
# with that channel's [omarchy] repo and Arch Linux ARM mirror, as x86_64's
# pacman-online-<channel>.conf are.
for channel in stable rc edge; do
  conf=$ROOT/configs/pacman-online-aarch64-$channel.conf
  [[ -f $conf ]] || fail "no aarch64 online pacman config for $channel"
  host=arm-mirror.omarchy.org
  [[ $channel == edge ]] || host=arm-$channel-mirror.omarchy.org
  repos=$(grep -E '^\[|^Server' "$conf" | grep -v '^\[options\]' | paste -sd' ')
  [[ $repos == "[platform] Server = file:///packages [omarchy] Server = https://pkgs.omarchy.org/$channel/\$arch [core] Server = https://$host/\$arch/\$repo [extra] Server = https://$host/\$arch/\$repo [alarm] Server = https://$host/\$arch/\$repo [aur] Server = https://$host/\$arch/\$repo" ]] \
    || fail "aarch64 $channel repositories are wrong: $repos"
  diff <(grep -Ev '^Server|^#' "$ROOT/configs/pacman-online-aarch64-edge.conf") <(grep -Ev '^Server|^#' "$conf") >/dev/null \
    || fail "aarch64 $channel config differs from edge's in more than its servers"
done
grep -Fq 'sed -i "s|^Server = https://pkgs' "$ROOT/builder/build-iso.sh" && fail "an aarch64 build still rewrites its [omarchy] server"
grep -Fq 'repo-add -q "$bundle_index/platform.db.tar.gz"' "$ROOT/builder/build-iso.sh" || fail "bundle is not indexed as the [platform] repo"
grep -Fq 'arch="${OMARCHY_ARCH:-x86_64}"' "$ROOT/configs/profiledef.sh" || fail "profiledef ignores OMARCHY_ARCH"
# The live initramfs size gate looks where mkarchiso puts it for the build's
# architecture: <install_dir>/boot/<arch>. The builder's own gate, run on a
# small and an oversized initramfs for each architecture.
initramfs_gate=$(sed -n '/^live_initramfs_limit=/,/^done$/p' "$ROOT/builder/build-iso.sh")
[[ -n $initramfs_gate ]] || fail "the builder no longer gates the live initramfs size"
for platform in x86_64 aarch64; do
  mkdir -p "$fixture/gate-$platform/work/iso/arch/boot/$platform"
  live_img="$fixture/gate-$platform/work/iso/arch/boot/$platform/initramfs-linux-omarchy.img"
  truncate -s 96M "$live_img"
  (build_cache_dir="$fixture/gate-$platform" iso_subdir=arch/$platform OMARCHY_ARCH=$platform; eval "$initramfs_gate") >/dev/null 2>&1 \
    || fail "the live initramfs size gate does not find the $platform initramfs"
  truncate -s 129M "$live_img"
  (build_cache_dir="$fixture/gate-$platform" iso_subdir=arch/$platform OMARCHY_ARCH=$platform; eval "$initramfs_gate") >/dev/null 2>&1 \
    && fail "a 129 MiB $platform live initramfs passes the 128 MiB gate"
done

# --- GRUB templating -----------------------------------------------------------
for cfg in grub.cfg loopback.cfg; do
  src="$ROOT/configs/grub/$cfg"
  grep -Fqx 'set live_kernel=%KERNEL%' "$src" || fail "$cfg does not template the kernel"
  grep -Fq 'vmlinuz-${live_kernel}' "$src" || fail "$cfg entries do not boot the selected kernel"
  grep -Fq "if [ \"\${sys_vendor}\" == 'Apple Inc.' ]; then" "$src" || fail "$cfg boots linux-t2 on a machine Apple did not make"
  grep -Fq '%BOOT_SPLASH_KERNEL_OPTIONS%%KERNEL_OPTIONS%' "$src" || fail "$cfg does not template boot options"
  grep -Fq -- "--id 'n1x-recovery'" "$src" || fail "$cfg lacks the N1x recovery entry"
  grep -Fq 'omarchy.n1x_recovery=1 acpi=nospcr' "$src" || fail "$cfg recovery entry lacks acpi=nospcr"
  grep -Fq "if [ \"\${product_name}\" == '83SS' ]; then" "$src" || fail "$cfg does not limit acpi_osi=! to the Lenovo Pro 9"
  grep -Fqx 'set lenovo_osi=' "$src" || fail "$cfg does not leave lenovo_osi empty when SMBIOS does not match"
  grep -Fq "set lenovo_osi='acpi_osi=!'" "$src" || fail "$cfg never assigns acpi_osi=!"
  awk '/83SS/{p=1} p{print} p && /^[[:space:]]*fi$/{exit}' "$src" | grep -Fq "set lenovo_osi='acpi_osi=!'" \
    || fail "$cfg assigns acpi_osi=! outside the 83SS match"
  linux_lines=$(grep -E '^[[:space:]]*linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-' "$src")
  linux_count=$(printf '%s\n' "$linux_lines" | grep -c .)
  osi_count=$(printf '%s\n' "$linux_lines" | grep -c ' ${lenovo_osi}$')
  (( linux_count >= 3 && linux_count == osi_count )) || fail "$cfg does not pass lenovo_osi on every live linux line ($osi_count/$linux_count)"
  source "$ROOT/builder/grub-platform.sh"
  for platform in x86_64 aarch64; do
    cp "$src" "$fixture/$platform-$cfg"
    configure_grub_platform "$fixture/$platform-$cfg" "$platform"
    sed -i -e 's|%KERNEL%|linux-omarchy|g' -e 's|%BOOT_SPLASH_KERNEL_OPTIONS%|quiet splash |g' -e 's|%KERNEL_OPTIONS%|console=tty0|g' \
      -e 's|%INSTALL_DIR%|arch|g' -e "s|%ARCH%|$platform|g" -e 's|%ARCHISO_UUID%|x|g' "$fixture/$platform-$cfg"
    if command -v grub-script-check >/dev/null; then
      grub-script-check "$fixture/$platform-$cfg" || fail "$cfg ($platform) is not valid GRUB script"
    fi
    if [[ $platform == aarch64 ]]; then
      grep -Fq 'n1x-recovery' "$fixture/$platform-$cfg" || fail "the aarch64 menu lost the N1x recovery entry in $cfg"
    else
      grep -Fq 'n1x-recovery' "$fixture/$platform-$cfg" && fail "recovery entry leaked into the $platform $cfg"
    fi
    grep -Eq '^%N1X_ONLY' "$fixture/$platform-$cfg" && fail "template markers remain in $cfg"
    grep -Fqx 'timeout_style=hidden' "$fixture/$platform-$cfg" || fail "$cfg ($platform) shows the boot menu"
    grep -Fqx 'timeout=0' "$fixture/$platform-$cfg" || fail "$cfg ($platform) waits at the boot menu"
  done
done

# --- arm64 archiso patch still applies to the pinned submodule ---------------
if have_archiso; then
  cp "$ROOT/archiso/archiso/mkarchiso" "$fixture/mkarchiso"
  patch --batch --forward --fuzz=0 --dry-run "$fixture/mkarchiso" <"$ROOT/builder/archiso-v87-aarch64-grub.patch" >/dev/null \
    || fail "archiso arm64 GRUB patch no longer applies to the pinned submodule"
fi

# The device tree entry is the default only where the processor is a Snapdragon:
# every other machine on the same image boots the kernel directly.
grub="$ROOT/configs/grub/grub.cfg"
grep -Fq 'smbios --type 4 --get-string 7 --set cpu_maker' "$grub" || fail "GRUB does not ask the firmware who made the processor"
[[ $(grep -c 'default=archlinux-uki' "$grub") == $(grep -B1 'default=archlinux-uki' "$grub" | grep -c "regexp '") ]] \
  || fail "the device tree entry is the default on a machine that is not a Snapdragon"

# --- manifest filter -----------------------------------------------------------
source "$ROOT/builder/aarch64-package-filter.sh"
result=$(filter_aarch64_packages linux-omarchy linux linux-headers linux-omarchy linux-omarchy-headers amd-ucode broadcom-wl-dkms tzupdate lib32-nvidia-utils dell-xps13-sidecar-amps linux-firmware-cirrus-dx13260 apple-bcm-firmware-fetcher superwhisper-bin mise-bin nvim vi obs-studio yay-debug hyprland omarchy-dev 2>/dev/null | tr '\n' ' ')
[[ $result == "linux-omarchy linux-omarchy-headers linux-omarchy linux-omarchy-headers tzupdate mise-bin neovim ex-vi-compat hyprland omarchy-dev " ]] || fail "manifest filter produced: $result"
# The N1x list names linux-omarchy, and keeps the name.
result=$(filter_aarch64_packages linux-omarchy linux-omarchy linux-omarchy-headers 2>/dev/null | paste -sd' ')
[[ $result == "linux-omarchy linux-omarchy-headers" ]] || fail "linux-omarchy lost its name on its own image: $result"

grep -Fq -- '-e "OMARCHY_RUNTIME_PACKAGE=${OMARCHY_RUNTIME_PACKAGE:-}"' "$ROOT/bin/omarchy-iso-make" \
  || fail "the Omarchy package pair cannot be overridden for a --local-source build"

# --- N1x packages ----------------------------------------------------------------
grep -Fq 'OMARCHY_PLATFORM' "$ROOT/builder/build-omarchy-packages.sh" \
  && fail "the local package build still passes a platform no recipe reads"
grep -Fq 'lacks $required, which an aarch64 install needs' "$ROOT/builder/build-iso.sh" \
  || fail "aarch64 builds do not verify the settings package keeps the Limine drop-ins"
grep -Fq 'depend = limine-mkinitcpio-hook' "$ROOT/builder/build-iso.sh" \
  && fail "N1x builds still require the aarch64 runtime to depend on Limine"
grep -Fq 'pacman -Qqp "$archive"' "$ROOT/builder/build-iso.sh" \
  || fail "the offline mirror does not carry every package in the platform bundle"
grep -Fq 'archlinuxarm-keyring limine limine-mkinitcpio-hook limine-snapper-sync snapper pciutils' "$ROOT/builder/build-iso.sh" \
  || fail "the offline mirror lacks the Limine/Snapper stack the installer adds"
grep -Fq '"${base_pkg_lists[@]}" "${platform_lists[@]}"' "$ROOT/builder/build-iso.sh" \
  || fail "the offline mirror does not carry every platform's own packages"
# What the ISO ships is looked up in the same repositories the mirror was
# downloaded from: on aarch64 that is the bundle and Arch Linux ARM, which the
# x86_64 config does not name. The builder's own lookup, run against the
# aarch64 config's repositories synced, one package in the bundle and one in
# Arch Linux ARM's own repository.
sync_db() { # repository, and the package it holds, if any
  mkdir -p "$fixture/offlinedb/sync" "$fixture/repo-$1"
  if [[ -n ${2:-} ]]; then
    mkdir -p "$fixture/repo-$1/$2-1.0-1"
    printf '%%FILENAME%%\n%s-1.0-1-aarch64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n1.0-1\n\n%%ARCH%%\naarch64\n\n' "$2" "$2" \
      >"$fixture/repo-$1/$2-1.0-1/desc"
  fi
  ls "$fixture/repo-$1" | bsdtar -czf "$fixture/offlinedb/sync/$1.db" -C "$fixture/repo-$1" -T -
}
for repo in $(sed -n 's/^\[\(.*\)\]$/\1/p' "$ROOT/configs/pacman-online-aarch64-edge.conf" | grep -vx options); do
  sync_db "$repo"
done
sync_db platform bundle-only
sync_db alarm alarm-only
lookup=$(sed -n '/^if ! installable_files="\$($/,/^fi$/p' "$ROOT/builder/build-iso.sh")
[[ -n $lookup ]] || fail "the builder no longer looks up what an install can ask for"
lookup=${lookup//\/tmp\/offlinedb/$fixture/offlinedb}
lookup=${lookup//\/configs\//$ROOT/configs/}
installable=$(
  OMARCHY_ARCH=aarch64 OMARCHY_MIRROR=edge
  online_pacman_conf=$ROOT/configs/pacman-online-aarch64-edge.conf
  target_packages=(bundle-only alarm-only)
  eval "$lookup" 2>/dev/null
  printf '%s\n' "$installable_files" | sort | paste -sd' '
) || true
[[ $installable == 'alarm-only-1.0-1-aarch64.pkg.tar.zst bundle-only-1.0-1-aarch64.pkg.tar.zst' ]] \
  || fail "an aarch64 build looks up what it ships in other repositories than it downloaded from: '$installable'"

# The boot-time mirror check (omarchy-mirror-verify.service) runs the
# builder's checksum list before anything formats a disk. validate_boot reads
# archlinuxarm-keyring's signature off the shipped mirror after the image is
# written, so a damaged signature has to fail that check, not the finished
# install. The builder's own list, over a shipped mirror whose keyring
# signature is then damaged.
sums_block=$(sed -n '/^mirror_files() {/,/sha256sum) >"\$mirror_sums"$/p' "$ROOT/builder/build-iso.sh")
[[ -n $sums_block ]] || fail "the builder no longer checksums the shipped mirror"
shipped_mirror=$fixture/shipped-mirror
mkdir -p "$shipped_mirror" "$fixture/sums-cache/airootfs/usr/share/omarchy-iso"
for file in archlinuxarm-keyring-20240419-1-any.pkg.tar.xz{,.sig} linux-firmware-1-1-any.pkg.tar.zst{,.sig} \
  omarchy-local-1-1-any.pkg.tar.zst offline.db.tar.gz; do
  echo "$file" >"$shipped_mirror/$file"
done
printf '%s\n' archlinuxarm-keyring-20240419-1-any.pkg.tar.xz linux-firmware-1-1-any.pkg.tar.zst \
  omarchy-local-1-1-any.pkg.tar.zst >"$fixture/shipped.list"
(
  offline_mirror_dir=$shipped_mirror shipped_list=$fixture/shipped.list build_cache_dir=$fixture/sums-cache
  eval "$sums_block"
) || fail "the builder's mirror checksum list did not run"
shipped_sums=$fixture/sums-cache/airootfs/usr/share/omarchy-iso/offline-mirror.sha256
(cd "$shipped_mirror" && sha256sum --check --strict --quiet "$shipped_sums") \
  || fail "an intact shipped mirror fails its own checksums"
echo damaged >>"$shipped_mirror/archlinuxarm-keyring-20240419-1-any.pkg.tar.xz.sig"
(cd "$shipped_mirror" && sha256sum --check --strict --quiet "$shipped_sums") >/dev/null 2>&1 \
  && fail "a damaged archlinuxarm-keyring signature passes the boot-time mirror check"

# --- one image for every board ------------------------------------------------
# linux-omarchy and nothing else, and nothing that asks which board the image
# is for.
[[ ! -e $ROOT/builder/linux-aarch64-live.sh ]] || fail "the build still carries Arch Linux ARM's kernel as a live kernel"
grep -Fq "ERROR: aarch64 builds boot linux-omarchy" "$ROOT/builder/build-iso.sh" || fail "an aarch64 build accepts another kernel"
grep -Fq -- '--dev-ssh is only for aarch64 images' "$ROOT/builder/build-iso.sh" \
  || fail "a dev key would reach an x86_64 image"
grep -Fq 'kernel_options="console=tty0 acpi=nospcr initramfs_async=0"' "$ROOT/builder/build-iso.sh" \
  || fail "the N1x firmware's serial console would take the console from the panel"
# Without a bundle the [platform] repo must go: pacman refuses a repo it cannot sync.
strip=$(grep -F "awk '/^\\[platform\\]$/" "$ROOT/builder/build-iso.sh" | sed -E "s/.*awk '([^']*)'.*/\1/")
[[ -n $strip ]] || fail "builds without a bundle keep the [platform] repo"
stripped=$(awk "$strip" "$ROOT/configs/pacman-online-aarch64-stable.conf" | grep -E '^\[' | paste -sd' ')
[[ $stripped == '[options] [omarchy] [core] [extra] [alarm] [aur]' ]] || fail "repositories without a bundle are wrong: $stripped"
# The entrypoint's contract, checked by running it up to its first refusal.
make_refuses() { # expected message, then arguments
  local want=$1 out; shift
  out=$(cd "$ROOT" && bash bin/omarchy-iso-make "$@" 2>&1) && fail "omarchy-iso-make $* was accepted"
  grep -Fq -- "$want" <<<"$out" || fail "omarchy-iso-make $*: expected '$want', got: $out"
}
make_refuses 'package directory not found' --arch aarch64 --rc --package-dir /nonexistent
make_refuses 'package directory not found' --arch aarch64 --edge --package-dir /nonexistent
make_refuses 'Unknown option: --kernel' --arch aarch64 --edge --kernel linux-aarch64
make_refuses 'only valid with --arch aarch64' --package-dir /tmp
make_refuses 'Unknown option: --platform' --arch aarch64 --platform n1x --edge

# The live UKI that carries the Snapdragon laptops' device trees, since their
# firmware provides none. Every image tries to build one from its own kernel.
uki="$ROOT/builder/qualcomm/live-uki.sh"
bash -n "$uki"
grep -Fq 'parted systemd-ukify linux-firmware-qcom qcom-firmware-extract python)' "$ROOT/builder/build-iso.sh" \
  || fail "the live image lacks ukify or the Snapdragon firmware tools"
# The UKI is built in the image's customize step, once pacstrap has made the
# kernel and initramfs it wraps: the builder's own lines, run against the live
# root's customize_airootfs.sh.
insert_uki=$(sed -n '/^  customize="\$build_cache_dir\/airootfs\/root\/customize_airootfs.sh"$/,/ "\$customize"$/p' "$ROOT/builder/build-iso.sh")
[[ $(wc -l <<<"$insert_uki") == 3 ]] || fail "the builder no longer adds the live UKI step to customize_airootfs.sh: $insert_uki"
mkdir -p "$fixture/cache/airootfs/root"
live_customize="$fixture/cache/airootfs/root/customize_airootfs.sh"
cp "$ROOT/configs/airootfs/root/customize_airootfs.sh" "$live_customize"
(build_cache_dir="$fixture/cache" OMARCHY_KERNEL=linux-omarchy; eval "$insert_uki") || fail "the live UKI step does not go into customize_airootfs.sh"
bash -n "$live_customize" || fail "customize_airootfs.sh is not valid bash with the live UKI step"
uki_line=$(grep -nx 'bash /root/qualcomm-live-uki.sh linux-omarchy' "$live_customize" | cut -d: -f1 || true)
[[ -n $uki_line ]] || fail "the live UKI is not told which kernel to wrap"
[[ $(sed -n "$((uki_line + 1))p" "$live_customize") == 'rm -f /root/qualcomm-live-uki.sh' ]] || fail "the live UKI script stays in the image"
# After set -euo pipefail, so a failed UKI fails the build, and before
# anything that can end the script early.
(( $(grep -nx 'set -euo pipefail' "$live_customize" | head -1 | cut -d: -f1) < uki_line )) || fail "the live UKI step runs before set -euo pipefail"
first_exit=$(grep -nE '^[^#]*\bexit\b' "$live_customize" | head -1 | cut -d: -f1 || true)
[[ -z $first_exit ]] || (( uki_line < first_exit )) || fail "customize_airootfs.sh can exit before the live UKI is built"
# Nothing else in the script changes.
diff <(sed '/live UKI\.$/d; /qualcomm-live-uki\.sh/d' "$live_customize" | cat -s) <(cat -s "$ROOT/configs/airootfs/root/customize_airootfs.sh") >/dev/null \
  || fail "adding the live UKI step changed the rest of customize_airootfs.sh"
printf '#!/bin/bash\necho no strict mode\n' >"$live_customize"
(build_cache_dir="$fixture/cache" OMARCHY_KERNEL=linux-omarchy; eval "$insert_uki") 2>/dev/null \
  && fail "the live UKI step was added to a customize_airootfs.sh without set -euo pipefail"
grep -Fq -- '--devicetree-auto=$dtb' "$uki" || fail "the live UKI carries no device trees"
grep -Fq '*-el2.dtb' "$uki" || fail "EL2 device trees, which share hardware ids with their base trees, are not left out"
# A kernel that ships no Snapdragon device trees gets no UKI, and the build goes on.
if [[ ! -d /boot/dtbs/linux-omarchy/qcom ]]; then
  out=$(bash "$uki" linux-omarchy) || fail "a kernel without Snapdragon device trees stops the build"
  grep -Fq 'ships no Windows-on-ARM device trees' <<<"$out" || fail "a missing live UKI is not explained: $out"
fi
grep -Fq "chainloader /%INSTALL_DIR%/boot/%ARCH%/omarchy-live.efi" "$ROOT/configs/grub/grub.cfg" || fail "GRUB does not chainload the live UKI"
grep -F 'chainloader /%INSTALL_DIR%/boot/%ARCH%/omarchy-live.efi' "$ROOT/configs/grub/grub.cfg" | grep -Fq 'omarchy.qcom_early=1' || fail "the live UKI does not enable early Qualcomm startup"
grep -F 'chainloader /%INSTALL_DIR%/boot/%ARCH%/omarchy-live.efi' "$ROOT/configs/grub/grub.cfg" | grep -Fq 'modprobe.blacklist=qcom_q6v5_pas' || fail "the live UKI must protect the legacy path from automatic DSP startup"
grep -F 'omarchy-live.efi' "$ROOT/configs/grub/grub.cfg" | grep -Fq ' iommu.passthrough=0 ' || fail "the live UKI entry leaves device memory access untranslated"
grep -Fqx 'dtb_dir=/boot/dtbs/$1/qcom' "$uki" || fail "the live UKI does not take the device trees the kernel keeps under its own name"
# mkarchiso copies the UKI onto the ISO only with this patch, applied after the GRUB one.
if have_archiso; then
  cp "$ROOT/archiso/archiso/mkarchiso" "$fixture/mkarchiso-qualcomm"
  patch --batch --forward --fuzz=0 "$fixture/mkarchiso-qualcomm" <"$ROOT/builder/archiso-v87-aarch64-grub.patch" >/dev/null \
    && patch --batch --forward --fuzz=0 "$fixture/mkarchiso-qualcomm" <"$ROOT/builder/archiso-v87-aarch64-boot-efi.patch" >/dev/null \
    || fail "the archiso patch that copies the live UKI no longer applies to the pinned submodule"
  grep -Fq 'install -m 0644 -- "${uki}" "${isofs_dir}/${install_dir}/boot/${arch}/"' "$fixture/mkarchiso-qualcomm" \
    || fail "the patched mkarchiso does not copy the live UKI"
fi
grep -Fq 'patch --batch --forward --fuzz=0 "$mkarchiso_command" </builder/archiso-v87-aarch64-boot-efi.patch' "$ROOT/builder/build-iso.sh" \
  || fail "aarch64 builds do not patch mkarchiso to copy the live UKI"
# The installer asks the runtime's own detector which board it is on.
grep -Fq 'install -Dm0644 "$hw_platform" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-hw-platform"' "$ROOT/builder/build-iso.sh" \
  || fail "the image does not carry the runtime's platform detector"
# A packaged runtime links /usr/share/omarchy/bin/* to /usr/bin, so the link
# extracted on its own points nowhere.
grep -Fq 'hw_platform=/tmp/omarchy-pkglists/usr/bin/omarchy-hw-platform' "$ROOT/builder/build-iso.sh" \
  || fail "a build from published packages reads the detector through its link"

# --- package sources ---------------------------------------------------------------
# Arch Linux ARM's packages come from Omarchy's own mirror of them: for the
# offline mirror, for the build container, and for the installed system.
servers=$(cat "$ROOT"/configs/pacman-online-aarch64-*.conf | grep -E '^Server' | grep -v 'file:///packages' | sort -u)
grep -vq 'omarchy\.org/' <<<"$servers" && fail "an aarch64 build downloads from outside Omarchy: $(grep -v 'omarchy\.org/' <<<"$servers")"
grep -Fq 'Server = https://arm-mirror.omarchy.org/$arch/$repo' <<<"$servers" || fail "aarch64 builds do not use Omarchy's Arch Linux ARM mirror"
grep -Fq '>/etc/pacman.d/mirrorlist' "$ROOT/builder/build-iso.sh" || fail "the build container keeps the mirror its image came with"
grep -Fq '{"url": "https://arm-mirror.omarchy.org/$arch/$repo"}' "$ROOT/configs/airootfs/root/configurator" \
  || fail "an installed aarch64 system is not pointed at Omarchy's mirror"
if grep -rn 'mirror\.archlinuxarm\.org' "$ROOT/bin" "$ROOT/builder" "$ROOT/configs" >/dev/null; then
  fail "something still names Arch Linux ARM's own mirror"
fi

# --- recovery entry --------------------------------------------------------------
grep -Fq "grep -qw 'omarchy.n1x_recovery=1' /proc/cmdline" "$ROOT/configs/airootfs/root/.automated_script.sh" \
  || fail "the N1x recovery entry would start the installer"

# --- DEV ONLY: N1x debug SSH -------------------------------------------------------
dev_ssh="$ROOT/builder/n1x-dev-ssh/omarchy-n1x-dev-ssh"
grep -Fq 'install -Dm0755 /builder/n1x-dev-ssh/omarchy-n1x-dev-ssh' "$ROOT/builder/build-iso.sh" || fail "--dev-ssh builds do not stage the dev SSH script"
# The dev key is opt-in: only the --dev-ssh flag stages it.
dev_block=$(awk '/^if \[\[ -n \$\{OMARCHY_N1X_DEV_SSH:-\} \]\]; then$/,/^fi$/' "$ROOT/builder/build-iso.sh")
grep -Fq 'n1x-dev-ssh' <<<"$dev_block" || fail "dev SSH staging is not gated on OMARCHY_N1X_DEV_SSH"
[[ $(grep -c 'n1x-dev-ssh/' "$ROOT/builder/build-iso.sh") == $(grep -c 'n1x-dev-ssh/' <<<"$dev_block") ]] \
  || fail "dev SSH files are staged outside the --dev-ssh block"
grep -Fq -- '-e "OMARCHY_N1X_DEV_SSH=${N1X_DEV_SSH_KEY:+1}"' "$ROOT/bin/omarchy-iso-make" || fail "--dev-ssh does not reach the build container"
grep -Fq -- '-v "$N1X_DEV_SSH_KEY:/dev-ssh/authorized_keys:ro"' "$ROOT/bin/omarchy-iso-make" || fail "--dev-ssh does not hand the builder's key to the build"
grep -Fq -- '${N1X_DEV_SSH_KEY:+-devssh}' "$ROOT/bin/omarchy-iso-make" || fail "dev images are not named apart from normal ones"
grep -Fq 'file_permissions["/usr/local/sbin/omarchy-n1x-dev-ssh"]="0:0:755"' "$ROOT/builder/build-iso.sh" || fail "dev SSH script would lose its exec bit"
grep -Fq 'multi-user.target.wants/omarchy-n1x-dev-ssh.service' "$ROOT/builder/build-iso.sh" || fail "dev SSH unit is not enabled on the live ISO"
[[ ! -e $ROOT/builder/n1x-dev-ssh/authorized_keys ]] || fail "a dev SSH key is baked into the sources"
ssh-keygen -q -t ed25519 -N '' -C omarchy-iso-test -f "$fixture/devkey"
mkdir -p "$fixture/target/etc"
for run in 1 2; do
  OMARCHY_N1X_DEV_SSH_KEYS="$fixture/devkey.pub" bash "$dev_ssh" --target "$fixture/target" \
    || fail "dev SSH --target run $run failed"
done
[[ $(stat -c %a "$fixture/target/root/.ssh") == 700 && $(stat -c %a "$fixture/target/root/.ssh/authorized_keys") == 600 ]] \
  || fail "dev SSH wrote loose permissions"
cmp -s "$fixture/target/root/.ssh/authorized_keys" "$fixture/devkey.pub" || fail "dev SSH key is not authorized exactly once for root"
grep -Fqx 'PasswordAuthentication no' "$fixture/target/etc/ssh/sshd_config.d/05-omarchy-n1x-dev-ssh.conf" || fail "dev SSH leaves password login on"
grep -Fqx 'PermitRootLogin prohibit-password' "$fixture/target/etc/ssh/sshd_config.d/05-omarchy-n1x-dev-ssh.conf" || fail "dev SSH root login is not key-only"
[[ ! -e $fixture/target/root/authorized_keys ]] || fail "--target must not stage installer keys"
# sshd keeps the first value it reads; the drop-in must sort before releng's.
for dropin in "$ROOT"/archiso/configs/releng/airootfs/etc/ssh/sshd_config.d/*.conf; do
  [[ -e $dropin ]] || continue
  [[ 05-omarchy-n1x-dev-ssh.conf < ${dropin##*/} ]] || fail "dev SSH drop-in sorts after releng's ${dropin##*/}"
done
bash "$dev_ssh" --target "$fixture/missing" 2>/dev/null && fail "dev SSH accepted a target that is not a root filesystem"

# --- default package set -----------------------------------------------------
# aarch64 composes the runtime's default sets the way omarchy-pkg-defaults does:
# the plain one, and one for each platform the installer may find itself on.
mkdir -p "$fixture/lists"
printf '%s\n' '# base' base-one gliff superwhisper-bin base-two >"$fixture/lists/omarchy-base.packages"
printf '%s\n' '# aarch64' zram-generator rtkit base-one >"$fixture/lists/omarchy-aarch64.packages"
printf '%s\n' '# x86_64 only' gliff superwhisper-bin >"$fixture/lists/omarchy-x86_64-only.packages"
printf '%s\n' '# n1x' linux-omarchy rtkit >"$fixture/lists/omarchy-aarch64-n1x.packages"
printf '%s\n' '# qualcomm' vulkan-freedreno >"$fixture/lists/omarchy-aarch64-qualcomm.packages"
printf '%s\n' '# apple' asahi-audio >"$fixture/lists/omarchy-aarch64-apple.packages"
composed=$(
  base_pkg_lists=("$fixture/lists/omarchy-base.packages")
  OMARCHY_ARCH=aarch64
  eval "$(sed -n '/^# aarch64 takes the runtime/,/^fi$/p' "$ROOT/builder/build-iso.sh")" 2>/dev/null
  cat "${base_pkg_lists[0]}"
  echo "--"
  cat "$platform_base_dir/omarchy-base.aarch64-n1x.packages"
  echo "--"
  cat "$platform_base_dir/omarchy-base.aarch64-qualcomm.packages"
  echo "--"
  ls "$platform_base_dir"
  echo "--"
  printf '%s\n' "${platform_lists[@]##*/}"
)
[[ $composed == $'base-one\nbase-two\nzram-generator\nrtkit\n--\nbase-one\nbase-two\nzram-generator\nrtkit\nlinux-omarchy\n--\nbase-one\nbase-two\nzram-generator\nrtkit\nvulkan-freedreno\n--\nomarchy-base.aarch64-n1x.packages\nomarchy-base.aarch64-qualcomm.packages\n--\nomarchy-aarch64-n1x.packages\nomarchy-aarch64-qualcomm.packages' ]] \
  || fail "aarch64 does not get the base list plus its architecture's additions, and one set per platform apart from Apple Silicon: $composed"
composed=$(
  rm "$fixture/lists"/omarchy-aarch64*.packages "$fixture/lists/omarchy-x86_64-only.packages"
  base_pkg_lists=("$fixture/lists/omarchy-base.packages")
  OMARCHY_ARCH=aarch64
  eval "$(sed -n '/^# aarch64 takes the runtime/,/^fi$/p' "$ROOT/builder/build-iso.sh")" 2>/dev/null
  cat "${base_pkg_lists[0]}"
  ls "$platform_base_dir"
)
[[ $composed == $'base-one\ngliff\nsuperwhisper-bin\nbase-two' ]] \
  || fail "a runtime without the platform lists keeps its base list: $composed"

# --- live initramfs overlay -------------------------------------------------
source "$ROOT/builder/archiso-aarch64-mkinitcpio.sh"
cp "$ROOT/configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf" "$fixture/archiso.conf"
configure_archiso_aarch64_mkinitcpio "$fixture/archiso.conf"
grep -Eq '^HOOKS=\(' "$fixture/archiso.conf" || fail "live HOOKS line lost"
grep -Eq 'microcode|memdisk' "$fixture/archiso.conf" && fail "x86-only hooks remain in the aarch64 live initramfs"
grep -Eq '^HOOKS=\(.*\bplymouth\b' "$fixture/archiso.conf" || fail "Plymouth is missing from the aarch64 live initramfs"
grep -q '^MODULES=(i2c_mt65xx i2c_tegra i2c_hid i2c_hid_acpi hid_generic hid_multitouch ' "$fixture/archiso.conf" || fail "early keyboard modules missing"
# A Snapdragon laptop's platform drivers, for a kernel that builds them as
# modules. Each is optional, so a kernel without one still gets its image.
live_modules=$(sed -n 's/^MODULES=(\(.*\))$/\1/p' "$fixture/archiso.conf")
for module in gcc-x1e80100 pinctrl-x1e80100 qnoc-x1e80100 spmi-pmic-arb i2c-qcom-geni i2c-hid-of dwc3-qcom phy-qcom-qmp-combo; do
  [[ " $live_modules " == *" $module? "* ]] || fail "the live initramfs lacks the Snapdragon platform driver $module"
done
[[ " $live_modules " != *" qcom_q6v5_pas"* ]] || fail "the live initramfs loads the DSP driver"

echo "aarch64 build overlay tests passed"
