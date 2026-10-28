#!/bin/bash

set -e

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"
OMARCHY_ARCH="${OMARCHY_ARCH:-x86_64}"
OMARCHY_KERNEL="${OMARCHY_KERNEL:-linux-omarchy}"
# profiledef.sh reads both in the mkarchiso environment.
export OMARCHY_ARCH OMARCHY_KERNEL

source /builder/node-release.sh
source /builder/arm64-kernel-image.sh
source /builder/archiso-aarch64-mkinitcpio.sh
source /builder/grub-platform.sh

# The online pacman configuration drives every package download below: one per
# architecture and channel. On aarch64 it points at Omarchy's aarch64
# repository and its mirror of Arch Linux ARM in the build's channel, and at a
# package bundle mounted at /packages first when there is one.
case "$OMARCHY_ARCH" in
  x86_64)
    online_pacman_conf="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
    ;;
  aarch64)
    online_pacman_conf="/configs/pacman-online-aarch64-${OMARCHY_MIRROR}.conf"
    # One image serves every board, on one kernel.
    if [[ $OMARCHY_KERNEL != linux-omarchy ]]; then
      echo "ERROR: aarch64 builds boot linux-omarchy (got '$OMARCHY_KERNEL')" >&2
      exit 1
    fi
    if [[ -d /packages && ! -f /packages/SHA256SUMS ]]; then
      echo "ERROR: the package bundle mounted at /packages needs a SHA256SUMS" >&2
      exit 1
    fi
    if [[ ! -f $online_pacman_conf ]]; then
      echo "ERROR: aarch64 builds use the stable, rc or edge channel (got '$OMARCHY_MIRROR')" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: unsupported OMARCHY_ARCH: $OMARCHY_ARCH" >&2
    exit 1
    ;;
esac

# Edge, dev, and local-source ISOs install the dev packages explicitly. Those
# package recipes track the quattro branch. This avoids relying on pacman's
# provides=omarchy resolution and shows the real package names being tested in
# the offline mirror and target install. Every other ref, the default quattro
# build included, installs the published omarchy packages.
case "$OMARCHY_ISO_REF" in
  edge|dev|local)
    : "${OMARCHY_RUNTIME_PACKAGE:=omarchy-dev}"
    : "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings-dev}"
    ;;
  *)
    : "${OMARCHY_RUNTIME_PACKAGE:=omarchy}"
    : "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings}"
    ;;
esac
: "${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}"
export OMARCHY_RUNTIME_PACKAGE OMARCHY_SETTINGS_PACKAGE OMARCHY_NVIM_PACKAGE

# pacman 7 sandboxes its downloads with Landlock and fails every sync on a
# kernel without it (Namespace's AmpereOne arm64 machines): "restricting
# filesystem access failed because Landlock is not supported by the kernel".
# There, every pacman in this container (pacstrap's too) runs with
# --disable-sandbox, which pacman provides for exactly this. A wrapper rather
# than DisableSandbox in a config: pacman-offline.conf ships on the ISO.
if ! grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then
  echo "No Landlock in this kernel: pacman runs with --disable-sandbox in this container"
  printf '#!/bin/sh\nexec /usr/bin/pacman --disable-sandbox "$@"\n' >/usr/local/bin/pacman
  chmod +x /usr/local/bin/pacman
  hash -r
fi

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
# The [core] server of an online configuration: the build channel's Omarchy
# mirror, which the build container installs its own tools from.
channel_core_server() {
  local server
  server=$(awk '/^\[core\]$/ { getline server; print server; exit }' "$1")
  if [[ $server != "Server = https://"*"mirror.omarchy.org/"* ]]; then
    echo "ERROR: no Omarchy mirror for [core] in $1" >&2
    return 1
  fi
  printf '%s\n' "$server"
}

if [[ $OMARCHY_ARCH == aarch64 ]]; then
  channel_pacman_conf=$online_pacman_conf
  online_pacman_conf=/tmp/pacman-online-aarch64.conf
  if [[ -d /packages ]]; then
    # The platform bundle is the [platform] repo for this build. Verify it and
    # index it before pacman first consults it.
    if ! (cd /packages && sha256sum --check --strict --quiet SHA256SUMS); then
      echo "ERROR: package bundle checksum verification failed" >&2
      exit 1
    fi
    bundle_index=/tmp/packages-index
    rm -rf "$bundle_index"; mkdir -p "$bundle_index"
    # repo-add writes next to the archives, but /packages is read-only. Index a
    # symlink farm instead and serve the repo through it.
    for archive in /packages/*.pkg.tar.*; do
      [[ $archive == *.sig ]] && continue
      ln -s "$archive" "$bundle_index/${archive##*/}"
    done
    repo-add -q "$bundle_index/platform.db.tar.gz" "$bundle_index"/*.pkg.tar.* 2>/dev/null || \
      repo-add "$bundle_index/platform.db.tar.gz" "$bundle_index"/*.pkg.tar.*
    sed "s|^Server = file:///packages$|Server = file://$bundle_index|" "$channel_pacman_conf" > "$online_pacman_conf"
  else
    # No bundle, so no [platform] repo: pacman refuses a repo it cannot sync.
    awk '/^\[platform\]$/ { skip = 1; next } /^\[/ { skip = 0 } !skip' \
      "$channel_pacman_conf" > "$online_pacman_conf"
  fi

  # The container image arrives pointed at Arch Linux ARM's own mirrors. Its
  # packages come from the same place the ISO's do: Omarchy's mirror of them.
  channel_core_server "$online_pacman_conf" >/etc/pacman.d/mirrorlist || exit 1
  pacman --noconfirm -Sy archlinuxarm-keyring
  pacman-key --populate archlinuxarm
  # Arch Linux ARM does not publish archiso. Install its runtime dependencies
  # and run the repository's pinned submodule copy, patched for arm64-efi GRUB.
  pacman --noconfirm -Syu \
    arch-install-scripts dosfstools e2fsprogs erofs-utils libarchive libisoburn \
    mtools squashfs-tools git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli btrfs-progs
  mkarchiso_command=/tmp/mkarchiso-aarch64
  cp /archiso/archiso/mkarchiso "$mkarchiso_command"
  patch --batch --forward --fuzz=0 "$mkarchiso_command" </builder/archiso-v87-aarch64-grub.patch
  # A Snapdragon laptop boots the live system from a UKI built into /boot;
  # carry it onto the ISO beside the kernel when the build made one.
  patch --batch --forward --fuzz=0 "$mkarchiso_command" </builder/archiso-v87-aarch64-boot-efi.patch
  chmod 0755 "$mkarchiso_command"
else
  # The container's own tools come from the channel's Omarchy mirror too; the
  # image's mirrors stay after it as the fallback the online configuration
  # reaches through its Include.
  core_server=$(channel_core_server "$online_pacman_conf") || exit 1
  sed -i "1i $core_server" /etc/pacman.d/mirrorlist
  pacman --noconfirm -Sy archlinux-keyring
  # Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
  # so this container can be months behind the mirror it installs from. A plain
  # -Sy install is then a partial upgrade — new packages linked against a glibc
  # the container doesn't have yet.
  pacman --noconfirm -Syu archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli btrfs-progs
  mkarchiso_command=mkarchiso
fi

# The root image writer (builder/omarchy-image-write.c): build-root-image.sh
# packs the image with it below, and the live root ships it to write the image
# at install time. The container's libzstd is the one the live root gets.
# Built with Arch's own package flags (FORTIFY_SOURCE=3, stack clash
# protection, CET, full RELRO), like every other binary in the live root.
# Speed flags would not matter: the time is in libzstd and libc, which pick
# their code for the CPU at run time (-O2, Arch's flags and -O3 -march=native
# -flto all measure 0.78 s on the root image).
(
  source /etc/makepkg.conf
  # shellcheck disable=SC2086 # the flag lists are meant to split
  gcc -std=gnu11 $CFLAGS -Wall -Wextra -pthread $LDFLAGS \
    -o /usr/local/bin/omarchy-image-write /builder/omarchy-image-write.c -lzstd
)

# Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
# during the build without keyserver lookups).
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# omarchy-keyring is needed inside the offline mirror too.
pacman --config "$online_pacman_conf" --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Put OPR first in the container too so makepkg resolves the same overrides
# as the online installer configuration.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
  opr_section=$(awk '/^\[omarchy\]/,/^$/' "$online_pacman_conf")
  awk -v opr="$opr_section" '/^\[core\]/ { print opr; print "" } { print }' \
    /etc/pacman.conf >/tmp/pacman-opr-first.conf
  install -m 644 /tmp/pacman-opr-first.conf /etc/pacman.conf
  rm -f /tmp/pacman-opr-first.conf
fi

# Build locations
build_cache_dir=/var/cache
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$build_cache_dir" "$offline_mirror_dir"

# Seed from the official Arch releng profile.
cp -r /archiso/configs/releng/* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# We rely on the global CDN; drop reflector.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our archiso profile additions.
cp -r /configs/* "$build_cache_dir/"
install -Dm755 /usr/local/bin/omarchy-image-write "$build_cache_dir/airootfs/usr/local/bin/omarchy-image-write"
mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"
echo "$OMARCHY_ISO_REF" > "$build_cache_dir/airootfs/root/omarchy_iso_ref"
echo "$OMARCHY_ARCH" > "$build_cache_dir/airootfs/root/omarchy_arch"
# The kernel the installer puts on the target: the image's own on aarch64,
# empty on x86_64, where the installer picks per machine.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  echo "$OMARCHY_KERNEL" > "$build_cache_dir/airootfs/root/omarchy_kernel"
else
  : > "$build_cache_dir/airootfs/root/omarchy_kernel"
fi

# The live kernel's archiso initramfs. x86_64 also keeps linux-t2's, which
# GRUB boots on a Mac (configs/grub/grub.cfg).
cp "/builder/${OMARCHY_KERNEL}.preset" "$build_cache_dir/airootfs/etc/mkinitcpio.d/${OMARCHY_KERNEL}.preset"

# Architecture overlay on the shared profile: live kernel, initramfs hooks,
# GRUB entries.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  # releng's live package list is x86-flavoured; drop what arm64 cannot use.
  arm_live_excludes=(amd-ucode broadcom-wl edk2-shell hyperv intel-ucode linux memtest86+ memtest86+-efi open-vm-tools refind reflector syslinux virtualbox-guest-utils-nox)
  cp "$build_cache_dir/packages.x86_64" "$build_cache_dir/packages.aarch64"
  for excluded_package in "${arm_live_excludes[@]}"; do
    escaped_package=${excluded_package//+/[+]}
    sed -i "\\|^${escaped_package}$|d" "$build_cache_dir/packages.aarch64"
  done
  rm -f "$build_cache_dir/packages.x86_64"
  rm -f "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset" "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset"
  # Drops the x86-only microcode/memdisk hooks and adds the Tegra/MediaTek
  # I2C-HID keyboard modules.
  configure_archiso_aarch64_mkinitcpio "$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  # The initramfs waits for the live medium only on x86_64 (configs/airootfs/
  # etc/initcpio/hooks/udev); the aarch64 boards keep the full settle, which
  # the Qualcomm firmware staging before media discovery was proven with.
  rm -f "$build_cache_dir/airootfs/etc/initcpio/hooks/udev"
  boot_splash_kernel_options="quiet splash "
  # The N1x firmware's SPCR serial console would take the console from the
  # panel, hence console=tty0 acpi=nospcr.
  kernel_options="console=tty0 acpi=nospcr initramfs_async=0"
  # Snapdragon firmware hands the kernel no device tree. Once the live kernel
  # and initramfs exist, wrap them in a UKI that carries the device trees the
  # kernel package ships; GRUB chainloads it where there is one
  # (configs/grub/grub.cfg).
  install -Dm0644 /builder/qualcomm/live-uki.sh "$build_cache_dir/airootfs/root/qualcomm-live-uki.sh"
  # Into the live root's customize_airootfs.sh, ahead of its pruning of the
  # mirror, which can end the script early.
  customize="$build_cache_dir/airootfs/root/customize_airootfs.sh"
  grep -qx 'set -euo pipefail' "$customize" || { echo "ERROR: $customize has no 'set -euo pipefail' line to start after" >&2; exit 1; }
  sed -i "0,/^set -euo pipefail\$/s||set -euo pipefail\\n\\n# The Snapdragon laptops' live UKI.\\nbash /root/qualcomm-live-uki.sh $OMARCHY_KERNEL\\nrm -f /root/qualcomm-live-uki.sh|" "$customize"
  # Keep the existing late-start path when early firmware is unavailable.
  install -Dm0755 /builder/qualcomm/omarchy-live-dsp "$build_cache_dir/airootfs/usr/local/bin/omarchy-live-dsp"
  install -Dm0644 /builder/qualcomm/omarchy-live-dsp.service "$build_cache_dir/airootfs/etc/systemd/system/omarchy-live-dsp.service"
  mkdir -p "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/omarchy-live-dsp.service "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-live-dsp.service"
  printf '%s\n' 'file_permissions["/usr/local/bin/omarchy-live-dsp"]="0:0:755"' >>"$build_cache_dir/profiledef.sh"
  install -Dm0755 /builder/qualcomm/early-startup-install "$build_cache_dir/airootfs/usr/lib/initcpio/install/qcom_early_startup"
  install -Dm0755 /builder/qualcomm/early-startup "$build_cache_dir/airootfs/usr/lib/initcpio/hooks/qcom_early_startup"
  install -Dm0644 /builder/qualcomm/early-firmware.py "$build_cache_dir/airootfs/usr/lib/initcpio/qcom-early-firmware.py"
  rm -rf "$build_cache_dir/syslinux" "$build_cache_dir/efiboot"
else
  boot_splash_kernel_options="quiet splash "
  kernel_options="xe.enable_panel_replay=0 initramfs_async=0 intel_idle.states_off=0x3fc"
fi
for grub_config in "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"; do
  configure_grub_platform "$grub_config" "$OMARCHY_ARCH"
  sed -i \
    -e "s|%KERNEL%|$OMARCHY_KERNEL|g" \
    -e "s|%BOOT_SPLASH_KERNEL_OPTIONS%|$boot_splash_kernel_options|g" \
    -e "s|%KERNEL_OPTIONS%|$kernel_options|g" \
    "$grub_config"
done
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  # The live system's name on the network (releng's Ethernet DHCP with mDNS).
  printf '%s\n' omarchy-n1x-rescue >"$build_cache_dir/airootfs/etc/hostname"
fi
if [[ -n ${OMARCHY_N1X_DEV_SSH:-} ]]; then
  # DEV ONLY (--dev-ssh): key-only SSH into the live ISO and the installed
  # system. See builder/n1x-dev-ssh/omarchy-n1x-dev-ssh; removing that
  # directory and this block removes it.
  if [[ $OMARCHY_ARCH != aarch64 ]]; then
    echo "ERROR: --dev-ssh is only for aarch64 images" >&2
    exit 1
  fi
  install -Dm0755 /builder/n1x-dev-ssh/omarchy-n1x-dev-ssh "$build_cache_dir/airootfs/usr/local/sbin/omarchy-n1x-dev-ssh"
  install -Dm0644 /dev-ssh/authorized_keys "$build_cache_dir/airootfs/usr/local/share/omarchy-n1x-dev-ssh/authorized_keys"
  install -Dm0644 /builder/n1x-dev-ssh/omarchy-n1x-dev-ssh.service "$build_cache_dir/airootfs/etc/systemd/system/omarchy-n1x-dev-ssh.service"
  mkdir -p "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/omarchy-n1x-dev-ssh.service "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-n1x-dev-ssh.service"
  printf '%s\n' 'file_permissions["/usr/local/sbin/omarchy-n1x-dev-ssh"]="0:0:755"' >>"$build_cache_dir/profiledef.sh"
fi
cat > "$build_cache_dir/airootfs/usr/share/omarchy-iso/package-targets" <<EOF
OMARCHY_RUNTIME_PACKAGE=$OMARCHY_RUNTIME_PACKAGE
OMARCHY_SETTINGS_PACKAGE=$OMARCHY_SETTINGS_PACKAGE
OMARCHY_NVIM_PACKAGE=$OMARCHY_NVIM_PACKAGE
EOF

if [[ ${OMARCHY_INSTALL_DEBUG:-} == "1" ]]; then
  touch "$build_cache_dir/airootfs/usr/share/omarchy-iso/install-debug"
  {
    echo "debug=1"
    echo "built_at=$(date -Is)"
    echo "ref=$OMARCHY_ISO_REF"
    echo "mirror=$OMARCHY_MIRROR"
    echo "runtime_package=$OMARCHY_RUNTIME_PACKAGE"
    echo "settings_package=$OMARCHY_SETTINGS_PACKAGE"
    echo "nvim_package=$OMARCHY_NVIM_PACKAGE"
    if [[ -d /omarchy-source ]]; then
      echo "omarchy_source=/omarchy-source"
      git -c safe.directory=/omarchy-source -C /omarchy-source rev-parse HEAD 2>/dev/null | sed 's/^/omarchy_commit=/' || true
      git -c safe.directory=/omarchy-source -C /omarchy-source status --short 2>/dev/null | sed 's/^/omarchy_status=/' || true
    fi
    if [[ -d /omarchy-pkgs ]]; then
      echo "omarchy_pkgs_source=/omarchy-pkgs"
      git -c safe.directory=/omarchy-pkgs -C /omarchy-pkgs rev-parse HEAD 2>/dev/null | sed 's/^/omarchy_pkgs_commit=/' || true
      git -c safe.directory=/omarchy-pkgs -C /omarchy-pkgs status --short 2>/dev/null | sed 's/^/omarchy_pkgs_status=/' || true
    fi
  } > "$build_cache_dir/airootfs/usr/share/omarchy-iso/build-info"
fi

# When --local-source is in effect, build omarchy* from the mounted source
# trees and drop them in the offline mirror. Otherwise pacman -Syw below
# downloads the published versions from the omarchy network mirror.
if [[ -d /omarchy-source && -d /omarchy-pkgs ]]; then
  bash /builder/build-omarchy-packages.sh "$offline_mirror_dir"
  LOCAL_OMARCHY_BUILD=1
  # A rebuild of the same revision produces the same filename with different
  # bytes. pacman consults /var/cache/pacman/pkg (the host's cache, kept across
  # --keep-pkg-cache builds) before the mirror, and a stale copy from an
  # earlier build fails the checksum against the mirror's fresh db.
  for local_package_name in \
    "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"; do
    rm -f /var/cache/pacman/pkg/"$local_package_name"-*.pkg.tar.zst{,.sig}
  done

  # Every board this image installs boots like the x86_64 machines: the
  # installer reads the Limine template, and the target needs the initramfs
  # hooks and Limine drop-ins. The installer adds the Limine/Snapper stack
  # itself on aarch64, where the runtime does not depend on it because Apple
  # Silicon boots differently.
  if [[ $OMARCHY_ARCH == aarch64 ]]; then
    settings_archive=$(find "$offline_mirror_dir" -maxdepth 1 -name "$OMARCHY_SETTINGS_PACKAGE-[0-9]*.pkg.tar.*" ! -name '*.sig' | head -1)
    for required in usr/share/omarchy/default/limine/default.conf etc/mkinitcpio.conf.d/omarchy_hooks.conf etc/limine-entry-tool.d/omarchy-defaults.conf; do
      if ! bsdtar -tf "$settings_archive" "$required" >/dev/null 2>&1; then
        echo "ERROR: ${settings_archive:-$OMARCHY_SETTINGS_PACKAGE} lacks $required, which an aarch64 install needs" >&2
        exit 1
      fi
    done
  fi
fi

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  # Plymouth stays out of the live initramfs (archiso-aarch64-mkinitcpio.sh);
  # openssh and pciutils serve the recovery entry and remote debugging.
  # For the Snapdragon laptops: ukify builds the live UKI, and the installer
  # saves a laptop's signed firmware from Windows with qcom-firmware-extract.
  arch_packages=("$OMARCHY_KERNEL" archlinuxarm-keyring git gum jq openssl openssh pciutils plymouth ttfx terminus-font tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted systemd-ukify linux-firmware-qcom qcom-firmware-extract python)
else
  # linux-t2 is the live kernel on a Mac (configs/grub/grub.cfg).
  arch_packages=("$OMARCHY_KERNEL" linux-t2 git gum jq openssl plymouth ttfx terminus-font tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)
fi
live_packages_file="$build_cache_dir/packages.$OMARCHY_ARCH"
printf '%s\n' "${arch_packages[@]}" >> "$live_packages_file"

# The live ISO boots linux-omarchy, or linux-t2 on a Mac, so stock linux is a
# kernel nobody boots: ~147MB of ISO, plus its own archiso initramfs.
#
# It cannot just be deleted — releng's broadcom-wl hard-depends on it, and it is
# the only releng package that does, so pacman would drag the kernel straight back
# in. broadcom-wl is a prebuilt module for stock linux and cannot load on the
# kernel we boot, so it has done nothing since we started booting T2 anyway. The
# install is entirely offline and the live environment needs no Wi-Fi driver.
#
# Anchored so linux-omarchy, linux-t2 and linux-firmware are untouched.
sed -i -E '/^(linux|broadcom-wl)$/d' "$live_packages_file"

# Build the offline mirror: everything pacstrap might want during the target
# install. With --local-source, the omarchy* packages we just built are
# already in the mirror and we filter them out below. Without it, pacman -Syw
# pulls the published omarchy* from the network mirror like any other package.
if [[ -d /omarchy-source ]]; then
  base_pkg_lists=(/omarchy-source/install/omarchy-base.packages /omarchy-source/install/omarchy-other.packages)
  child_pkg_list=/omarchy-source/install/omarchy-child.packages
  setup_form=/omarchy-source/install/provisioning/setup-form.sh
  mise_work=/omarchy-source/install/user/mise-work.sh
else
  # Pull the same package lists out of the freshly-downloaded Omarchy runtime
  # package so we don't need a local checkout in the non-local-source path.
  bootstrap_cache_dir=/tmp/omarchy-pkg-bootstrap
  rm -rf "$bootstrap_cache_dir" /tmp/offlinedb-bootstrap /tmp/omarchy-pkglists
  mkdir -p "$bootstrap_cache_dir" /tmp/offlinedb-bootstrap
  pacman --config "$online_pacman_conf" --noconfirm -Syw "$OMARCHY_RUNTIME_PACKAGE" --cachedir "$bootstrap_cache_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
  omarchy_pkg=$(find "$bootstrap_cache_dir" -maxdepth 1 -type f -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.zst" | sort | head -1)
  if [[ -z $omarchy_pkg ]]; then
    echo "ERROR: downloaded package for $OMARCHY_RUNTIME_PACKAGE not found in $bootstrap_cache_dir" >&2
    exit 1
  fi
  mkdir -p /tmp/omarchy-pkglists
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/omarchy-base.packages usr/share/omarchy/install/omarchy-other.packages
  base_pkg_lists=(/tmp/omarchy-pkglists/usr/share/omarchy/install/omarchy-base.packages /tmp/omarchy-pkglists/usr/share/omarchy/install/omarchy-other.packages)
  # Extracted on its own, tolerating a miss: bsdtar exits non-zero for a member
  # it can't find, so asking for this alongside the package lists would abort the
  # build here (set -e) with a bare "Not found in archive" instead of the
  # actionable error below.
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/provisioning/setup-form.sh 2>/dev/null || true
  setup_form=/tmp/omarchy-pkglists/usr/share/omarchy/install/provisioning/setup-form.sh
  # The child profile's list, tolerating a runtime that predates it the same
  # way: a missing member must not abort the build.
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/omarchy-child.packages 2>/dev/null || true
  child_pkg_list=/tmp/omarchy-pkglists/usr/share/omarchy/install/omarchy-child.packages
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/user/mise-work.sh 2>/dev/null || true
  mise_work=/tmp/omarchy-pkglists/usr/share/omarchy/install/user/mise-work.sh
  # The aarch64 list, each platform's own and the x86_64-only one. Runtimes
  # from before the platform lists ship none, so each is optional.
  for platform_list in 'omarchy-aarch64*.packages' omarchy-x86_64-only.packages; do
    bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists "usr/share/omarchy/install/$platform_list" 2>/dev/null || true
  done
  # The package installs its commands to /usr/bin and links them from
  # /usr/share/omarchy/bin, so the detector itself is the one in usr/bin.
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/bin/omarchy-hw-platform 2>/dev/null || true
fi

# One aarch64 image serves every board, so the runtime it installs has to tell
# them apart and carry each one's setup and packages. Refuse a runtime from
# before the platform detector, the Snapdragon setup or a platform's package
# list: a Snapdragon laptop installed from it would have no device tree to boot
# with, and a GB10 or an N1x would get none of its own packages.
platform_lists=()
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  for required in bin/omarchy-hw-platform install/hardware/qualcomm/dtb-uki.sh \
    install/omarchy-aarch64-qualcomm.packages install/omarchy-aarch64-n1x.packages \
    install/omarchy-aarch64-gb10.packages; do
    if [[ -d /omarchy-source ]]; then
      [[ -f /omarchy-source/$required ]]
    else
      bsdtar -tf "$omarchy_pkg" "usr/share/omarchy/$required" >/dev/null 2>&1
    fi || {
      echo "ERROR: the Omarchy runtime for this image ships no $required." >&2
      echo "       The installer asks the runtime's detector which board it is on and installs" >&2
      echo "       that platform's packages, and a Snapdragon laptop boots only with the device" >&2
      echo "       trees its hardware setup lists." >&2
      echo "       Build with --local-source against a checkout that has the platform support." >&2
      exit 1
    }
  done
  if [[ -d /omarchy-source ]]; then
    hw_platform=/omarchy-source/bin/omarchy-hw-platform
  else
    hw_platform=/tmp/omarchy-pkglists/usr/bin/omarchy-hw-platform
  fi
fi

# aarch64 takes the runtime's own default sets, as omarchy-pkg-defaults composes
# them: the base list, then the aarch64 additions (zram-generator, rtkit) and a
# platform's own (the N1x kernel and NVIDIA stack, say), minus the base packages
# with no aarch64 build anywhere (superwhisper-bin, say). The installer asks the
# machine which platform it is on and installs that platform's set, so the image
# carries one list per platform and the plain aarch64 one for every other
# machine. Apple Silicon is installed from macOS, never from this image.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  pkglist_dir=$(dirname "${base_pkg_lists[0]}")
  aarch64_default_set() {
    grep -hv '^#\|^$' "$@" | sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' |
      awk -v skips="$pkglist_dir/omarchy-x86_64-only.packages" '
        BEGIN { while ((getline line < skips) > 0) { sub(/[ \t]*#.*$/, "", line); if (line != "") skip[line] = 1 } }
        skip[$0] { print "aarch64: excluding " $0 ", which the runtime marks x86_64-only" > "/dev/stderr"; next }
        !seen[$0]++'
  }
  aarch64_lists=("${base_pkg_lists[0]}")
  [[ ! -f $pkglist_dir/omarchy-aarch64.packages ]] || aarch64_lists+=("$pkglist_dir/omarchy-aarch64.packages")
  platform_base_dir=/tmp/omarchy-platform-base
  rm -rf "$platform_base_dir"
  mkdir -p "$platform_base_dir"
  for platform_list in "$pkglist_dir"/omarchy-aarch64-*.packages; do
    [[ -f $platform_list && $platform_list != */omarchy-aarch64-apple.packages ]] || continue
    platform_lists+=("$platform_list")
    platform=${platform_list##*/omarchy-}
    aarch64_default_set "${aarch64_lists[@]}" "$platform_list" 2>/dev/null >"$platform_base_dir/omarchy-base.${platform%.packages}.packages"
  done
  aarch64_base_list=/tmp/omarchy-aarch64-base.packages
  aarch64_default_set "${aarch64_lists[@]}" >"$aarch64_base_list"
  base_pkg_lists[0]=$aarch64_base_list
fi

mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
cp "${base_pkg_lists[0]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
cp "${base_pkg_lists[1]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-other.packages"
shipped_lists=(omarchy-base.packages omarchy-other.packages)
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  # The runtime's own detector, which stands alone wherever a copy of it is
  # shipped, and the default set of each platform it can name.
  install -Dm0644 "$hw_platform" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-hw-platform"
  for platform_base in "$platform_base_dir"/omarchy-base.*.packages; do
    [[ -f $platform_base ]] || continue
    cp "$platform_base" "$build_cache_dir/airootfs/usr/share/omarchy-iso/"
    shipped_lists+=("${platform_base##*/}")
  done
fi
# The installer reads the shipped copies to pacstrap the target, so on aarch64
# they must carry the same substitutions the offline mirror was built with.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  source /builder/aarch64-package-filter.sh
  for shipped_list in "${shipped_lists[@]}"; do
    shipped_path="$build_cache_dir/airootfs/usr/share/omarchy-iso/$shipped_list"
    mapfile -t shipped_packages < <(grep -hv '^#\|^$' "$shipped_path")
    filter_aarch64_packages "$OMARCHY_KERNEL" "${shipped_packages[@]}" > "$shipped_path"
  done
  # archinstall's list is only read at build time; keep a filtered copy for the
  # resolution below.
  mapfile -t archinstall_packages < <(grep -hv '^#\|^$' /builder/archinstall.packages)
  filter_aarch64_packages "$OMARCHY_KERNEL" "${archinstall_packages[@]}" > /tmp/archinstall.packages
  archinstall_packages_file=/tmp/archinstall.packages
else
  archinstall_packages_file=/builder/archinstall.packages
fi

# What a child install (kids mode) adds on top of the base list. The
# orchestrator reads the vendored copy, so a runtime without one gets an
# empty list rather than a missing file.
if [[ -f $child_pkg_list ]]; then
  cp "$child_pkg_list" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-child.packages"
else
  echo "# No child package list in this runtime." >"$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-child.packages"
fi

# The configurator's setup form comes from the runtime this ISO bundles, so the
# installer and the first-boot setup that finishes a deferred install can never
# disagree. A runtime predating the split ships no such file, which would leave
# the configurator with no prompts at all.
if [[ ! -f $setup_form ]]; then
  if [[ -d /omarchy-source ]]; then
    echo "ERROR: the --local-source checkout ships no install/provisioning/setup-form.sh" >&2
    remedy="Update the checkout to a revision carrying the shared setup form."
  else
    echo "ERROR: $OMARCHY_RUNTIME_PACKAGE does not ship install/provisioning/setup-form.sh" >&2
    remedy="Publish a runtime carrying the shared setup form, or build with --local-source against a checkout that has it."
  fi
  echo "       The configurator sources its prompts from that file, so this ISO" >&2
  echo "       would boot into an installer with no questions to ask." >&2
  echo "       $remedy" >&2
  exit 1
fi
cp "$setup_form" "$build_cache_dir/airootfs/usr/share/omarchy-iso/setup-form.sh"

# Omarchy installs Node lazily through mise since omacom/omarchy#15876. A
# runtime from before it unpacks a bundled Node tarball during setup and stops
# the install without one, so it still gets the build for its architecture.
# Remove this once every channel's runtime installs Node lazily.
if grep -qF /opt/packages "$mise_work" 2>/dev/null; then
  # The version is resolved from the "latest" alias, the file is fetched from
  # its own versioned directory: the alias directory changes under a release,
  # and a CDN edge can answer 404 for the new filename there for hours.
  # Versioned paths never change once published.
  NODE_DIST="https://nodejs.org/dist"
  NODE_SHASUMS=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 "$NODE_DIST/latest/SHASUMS256.txt")
  node_platform=linux-x64
  [[ $OMARCHY_ARCH == aarch64 ]] && node_platform=linux-arm64
  if ! IFS=$'\t' read -r NODE_FILENAME NODE_SHA < <(select_node_release "$node_platform" <<<"$NODE_SHASUMS"); then
    echo "ERROR: could not find Node.js $node_platform release metadata" >&2
    exit 1
  fi
  NODE_VERSION=${NODE_FILENAME#node-}; NODE_VERSION=${NODE_VERSION%%-*}
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 "$NODE_DIST/$NODE_VERSION/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
  echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
  mkdir -p "$build_cache_dir/airootfs/opt/packages/"
  cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"
fi

# Collect every package we want available in the offline mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    cat "$live_packages_file"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}" "${platform_lists[@]}"
    # The child list is comment-only until the child app set lands, and grep
    # exits 1 when it selects nothing; under set -e that would end this group
    # here and silently drop every list after it from the mirror.
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-child.packages" || true
    grep -hv '^#\|^$' /builder/archinstall.packages
    # The root image is pacstrapped from the pruned mirror, so its packages
    # must be in the keep-set even when nothing in the lists depends on them.
    grep -hv '^#\|^$' /builder/image.packages
    # Always include the selected Omarchy packages so the target install can
    # find the runtime and companion packages in the offline mirror.
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u
)

# Arch dropped the prebuilt broadcom-wl on 2026-09-02 and rebuilt broadcom-wl-dkms
# with replaces=(broadcom-wl). A replaces entry only helps upgrades of an already
# installed package; as an explicit pacman target the old name now fails with
# "target not found". Published Omarchy runtime packages that predate the rename
# still list it in omarchy-other.packages, so map it here until every channel
# ships a runtime that names broadcom-wl-dkms itself.
# apple-bcm-firmware, which arch-mact2 dropped for apple-bcm-firmware-fetcher,
# is not mapped here: renamed_packages below follows it, into the
# mirror and into the install scripts that still ask for the old name.
mapfile -t all_packages < <(
  printf '%s\n' "${all_packages[@]}" |
    sed -e 's/^broadcom-wl$/broadcom-wl-dkms/' |
    sort -u
)

# The names an install can ask pacman for: everything above except the live
# system's own package list (packages.x86_64). The live root is pacstrapped
# from the same mirror, so its tools (grub, nmap, vim, espeak-ng, man pages ...)
# are downloaded too, but nothing on the target ever installs them; see the
# shipped-mirror selection below.
declare -a target_packages
mapfile -t target_packages < <(
  {
    grep -hv '^#\|^$' "${base_pkg_lists[@]}" "${platform_lists[@]}"
    grep -hv '^#\|^$' "$archinstall_packages_file"
    grep -hv '^#\|^$' /builder/image.packages
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sed 's/^broadcom-wl$/broadcom-wl-dkms/' | sort -u
)

# x86_64: Omarchy's optional list also names packages for aarch64 boards,
# which have no x86_64 build. Each exclusion is explicit and printed.
if [[ $OMARCHY_ARCH == x86_64 ]]; then
  aarch64_only=(asus-proart-p14-speaker-firmware iptsd surface-pro-11-sensors surface-pro-11-support)
  printf 'x86_64: excluding aarch64-only package %s\n' "${aarch64_only[@]}" >&2
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | grep -Fxv -f <(printf '%s\n' "${aarch64_only[@]}"))
  mapfile -t target_packages < <(printf '%s\n' "${target_packages[@]}" | grep -Fxv -f <(printf '%s\n' "${aarch64_only[@]}"))
fi

# aarch64: the Omarchy manifests are written for x86_64 machines. Swap the
# kernel for the platform kernel and drop packages that only exist for x86.
# Every exclusion is explicit and printed; anything else missing from the
# mirror still fails the build below.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  source /builder/aarch64-package-filter.sh
  mapfile -t all_packages < <(filter_aarch64_packages "$OMARCHY_KERNEL" "${all_packages[@]}")
  mapfile -t target_packages < <(filter_aarch64_packages "$OMARCHY_KERNEL" "${target_packages[@]}")
  # The kernel pair and the Limine/Snapper stack the installer adds on aarch64,
  # and everything in a package bundle (the ASUS ProArt P14's amplifier
  # firmware, say). Each platform's own packages come from its list above.
  platform_packages=()
  if [[ -d /packages ]]; then
    mapfile -t platform_packages < <(
      for archive in /packages/*.pkg.tar.*; do
        [[ $archive == *.sig ]] || pacman -Qqp "$archive"
      done
    )
  fi
  all_packages+=("$OMARCHY_KERNEL" "$OMARCHY_KERNEL-headers" "${platform_packages[@]}" archlinuxarm-keyring limine limine-mkinitcpio-hook limine-snapper-sync snapper pciutils)
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | sort -u)
  # An aarch64 install asks for the same ones.
  target_packages+=("$OMARCHY_KERNEL" "$OMARCHY_KERNEL-headers" "${platform_packages[@]}" archlinuxarm-keyring limine limine-mkinitcpio-hook limine-snapper-sync snapper)
  mapfile -t target_packages < <(printf '%s\n' "${target_packages[@]}" | sort -u)
fi

# Leaving the local builds out of the download also leaves out what they
# depend on, so a dependency no package list names (omarchy-dev's
# omarchy-themes-intros) would be missing from the mirror. Name each one,
# except what the local builds provide themselves (omarchy-settings-dev's
# omarchy-security-functions): asked for by name, pacman would fetch the
# published provider on top of the local build.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  local_pkginfo=$(
    for pkg in "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"; do
      for archive in "$offline_mirror_dir/$pkg"-[0-9]*.pkg.tar.*; do
        [[ $archive == *.sig ]] || bsdtar -xOf "$archive" .PKGINFO
      done
    done
  )
  mapfile -t local_provides < <(sed -n 's/^\(pkgname\|provides\) = //p' <<<"$local_pkginfo" | sed 's/[<>=].*//')
  mapfile -t local_depends < <(
    sed -n 's/^depend = //p' <<<"$local_pkginfo" | sed 's/[<>=].*//' |
      grep -Fxv -f <(printf '%s\n' "${local_provides[@]}") || true
  )
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" "${local_depends[@]}" | sort -u)
  # The install asks for what the local builds depend on, from the shipped mirror.
  mapfile -t target_packages < <(printf '%s\n' "${target_packages[@]}" "${local_depends[@]}" | sort -u)
fi

# With --local-source we already built these omarchy* packages directly into
# the mirror; strip them from the pacman -Syw list so it doesn't try to fetch
# the published versions on top.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  mapfile -t all_packages < <(
    printf '%s\n' "${all_packages[@]}" |
      grep -Fxv \
        -e "$OMARCHY_RUNTIME_PACKAGE" \
        -e "$OMARCHY_SETTINGS_PACKAGE" \
        -e "$OMARCHY_NVIM_PACKAGE" || true
  )
  # They are in the image, so never shipped; and the online db the closure is
  # resolved against does not know the local builds.
  mapfile -t target_packages < <(
    printf '%s\n' "${target_packages[@]}" |
      grep -Fxv \
        -e "$OMARCHY_RUNTIME_PACKAGE" \
        -e "$OMARCHY_SETTINGS_PACKAGE" \
        -e "$OMARCHY_NVIM_PACKAGE" || true
  )
fi

mkdir -p /tmp/offlinedb
# A package name the lists carry but no repository offers any more makes
# pacman -Syw fail as a whole ("target not found"), and the offline mirror is
# never written. Third-party repositories do this without notice: arch-mact2
# replaced apple-bcm-firmware with apple-bcm-firmware-fetcher (a different
# mechanism, it conflicts with the old name) while the published omarchy
# package list still names the old one. Sync the databases once, drop the
# names nothing offers, and warn. A builder cache that still holds the old
# file hides the failure.
pacman --config "$online_pacman_conf" --noconfirm -Sy --dbpath /tmp/offlinedb >/dev/null
mapfile -t offered < <(pacman --config "$online_pacman_conf" --dbpath /tmp/offlinedb -Slq | sort -u)
mapfile -t unresolved < <(comm -23 <(printf '%s\n' "${all_packages[@]}" | sort -u) <(printf '%s\n' "${offered[@]}"))
if (( ${#unresolved[@]} )); then
  # Groups and virtual names (base-devel, ttfx, ...) are not in -Slq; keep
  # anything -Sp can still turn into a download.
  mapfile -t unresolved < <(for p in "${unresolved[@]}"; do
    pacman --config "$online_pacman_conf" --dbpath /tmp/offlinedb -Sp "$p" >/dev/null 2>&1 || echo "$p"; done)
fi
# Dropping a name keeps the build alive but loses whatever needed the package,
# and the hardware-conditional ones are needed where no VM test looks: the
# runtime's T2 step asks for apple-bcm-firmware in one pacman -S with linux-t2,
# its headers, the audio config and t2fanrd, so "target not found" costs a T2
# Mac all five. A known rename is followed instead: the new name goes
# into the mirror here, and build-root-image.sh rewrites the old name in the
# image's install scripts (arch-mact2's package has no provides= for it).
# Only names nothing offers are looked up, so an entry goes inert by itself
# once the old name is back or the runtime stops asking for it.
declare -A renamed_packages=(
  [apple-bcm-firmware]=apple-bcm-firmware-fetcher
)
renamed_list="$build_cache_dir/airootfs/usr/share/omarchy-iso/renamed-packages.txt"
unresolved_list="$build_cache_dir/airootfs/usr/share/omarchy-iso/unresolved-packages.txt"
rm -f "$renamed_list" "$unresolved_list"
still_unresolved=()
for p in "${unresolved[@]}"; do
  new=${renamed_packages[$p]:-}
  if [[ -n $new ]] && printf '%s\n' "${offered[@]}" | grep -Fxq "$new"; then
    echo "NOTE: $p is gone from every repository; following its rename to $new" >&2
    all_packages+=("$new")
    printf '%s %s\n' "$p" "$new" >>"$renamed_list"
    mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | grep -Fxv "$p" | sort -u)
  else
    still_unresolved+=("$p")
  fi
done
unresolved=("${still_unresolved[@]}")
# The same renames and drops for the names an install can ask for.
for p in "${!renamed_packages[@]}"; do
  if [[ -f $renamed_list ]] && grep -q "^$p " "$renamed_list"; then
    mapfile -t target_packages < <(printf '%s\n' "${target_packages[@]}" | sed "s/^${p}\$/${renamed_packages[$p]}/" | sort -u)
  fi
done
if (( ${#unresolved[@]} )); then
  mapfile -t target_packages < <(printf '%s\n' "${target_packages[@]}" | grep -Fxv -f <(printf '%s\n' "${unresolved[@]}"))
fi
if (( ${#unresolved[@]} )); then
  echo "WARNING: dropping package names no configured repository offers: ${unresolved[*]}" >&2
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | grep -Fxv -f <(printf '%s\n' "${unresolved[@]}"))
  printf '%s\n' "${unresolved[@]}" > "$build_cache_dir/airootfs/usr/share/omarchy-iso/unresolved-packages.txt"
fi
download_offline_packages() {
  pacman --config "$online_pacman_conf" --noconfirm -Syw \
    "${all_packages[@]}" --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb --needed
}

# A repository may occasionally republish a package without changing its
# filename. Pacman detects that the persistent cached copy no longer matches
# the refreshed repository checksum and deletes it, but still fails the
# transaction. Retry once so the now-missing package is downloaded.
if ! download_offline_packages; then
  echo "Offline package download failed; retrying after pacman cleaned invalid cached files..." >&2
  download_offline_packages
fi

# mkarchiso expects the mirror at /var/cache/omarchy/mirror/offline inside the
# container (the airootfs path), and the root image is pacstrapped through the
# same path; symlink rather than duplicate.
mkdir -p /var/cache/omarchy/mirror
ln -sfn "$offline_mirror_dir" /var/cache/omarchy/mirror/offline

# Every package archive in the mirror, indexed from nothing by one repo-add per
# CPU: one alone hashes and lists a thousand packages one after another. On aarch64
# the mirror also holds the bundle's .pkg.tar.xz archives.
rebuild_offline_repo_db() {
  bash /builder/index-offline-mirror.sh "$offline_mirror_dir"
}

# Resolve the exact filenames chosen by the same synced package databases used
# for the download. Pruning by this transaction (rather than merely keeping the
# newest version of every cached package name) removes packages that have left
# the lists or dependency closure, such as an old Electron major version. This
# is the build cache: it keeps the whole closure so the next build downloads
# nothing; what the ISO ships is decided below.
if ! resolved_package_files="$(
  pacman --config "$online_pacman_conf" --noconfirm \
    --dbpath /tmp/offlinedb -S --print --print-format '%f' "${all_packages[@]}"
)"; then
  echo "ERROR: could not resolve the package files required by the offline mirror" >&2
  exit 1
fi
mapfile -t required_package_files <<< "$resolved_package_files"

# The online transaction intentionally excludes packages built from the local
# checkouts. Add those exact artifacts back to the keep-set after verifying
# that the local build left exactly one file for each selected package name.
# The settings package is a live ISO package; the runtime and nvim packages
# are only in the image now, but keeping all three in the mirror leaves
# omarchy-apply-system able to resolve them like any published build.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  for local_package_name in \
    "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"; do
    local_package_file=""
    for candidate in "$offline_mirror_dir/$local_package_name-"*.pkg.tar.*; do
      [[ -f $candidate && $candidate != *.sig ]] || continue
      read -r candidate_name _ < <(pacman -Qp "$candidate" 2>/dev/null) || continue
      [[ $candidate_name == "$local_package_name" ]] || continue
      if [[ -n $local_package_file ]]; then
        echo "ERROR: multiple local builds found for $local_package_name" >&2
        exit 1
      fi
      local_package_file="${candidate##*/}"
    done
    if [[ -z $local_package_file ]]; then
      echo "ERROR: local build not found for $local_package_name" >&2
      exit 1
    fi
    required_package_files+=("$local_package_file")
  done
fi

printf '%s\n' "${required_package_files[@]}" |
  bash /builder/prune-offline-mirror.sh "$offline_mirror_dir"

# Index the mirror only now, from scratch, so size/checksum/depends entries
# reflect only the package files selected for this build. The cache persists
# across builds and can hold several versions of a package; repo-add keeps
# whichever it processes last (a warning on downgrade, hidden by -q), and the
# glob orders by name, not version. Indexing the unpruned cache could build the
# root image from an older package than the mirror beside it advertises.
rebuild_offline_repo_db

# The root image holds what every install gets. archinstall.packages also
# names packages an install adds only on the machines that need them, so the
# shipped mirror carries them; the image leaves those out:
#   alsa-firmware, sof-firmware  archinstall's audio step adds each by the
#                                sound driver the live system loaded, and
#                                omarchy's sof-firmware.sh adds SOF on Intel
#                                audio DSPs
#   tailscale                    installed only when an autoinstall drive
#                                staged an auth key
# Both CPU microcodes stay in the image although a machine needs only one: the
# pre-built UKI is made with autodetect skipped, so its microcode hook bundles
# both, and every install early-loads its own on first boot.
# omarchy-apply-system still installs more from omarchy-other.packages as the
# hardware dictates.
per_machine_packages=(alsa-firmware sof-firmware tailscale)

# On aarch64 the image also holds what the x86_64 runtime pulls in by
# dependency and the aarch64 one does not: the Limine/Snapper stack, which UEFI
# aarch64 machines boot like x86_64 ones; and archlinuxarm-keyring, whose keys
# sign every Arch Linux ARM package (the installer populates it with the rest).
image_arch_packages=()
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  image_arch_packages=(archlinuxarm-keyring limine-mkinitcpio-hook limine-snapper-sync snapper)
fi
image_package_list() {
  {
    # The architecture's list: on aarch64 the kernel is the image's and the
    # x86_64-only packages are gone.
    grep -hv '^#\|^$' "$archinstall_packages_file" |
      grep -Fxv -f <(printf '%s\n' "${per_machine_packages[@]}") || true
    grep -hv '^#\|^$' /builder/image.packages
    ((${#image_arch_packages[@]} == 0)) || printf '%s\n' "${image_arch_packages[@]}"
    # The shipped copy, which is what the install reads too.
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u
}
mapfile -t image_packages < <(image_package_list)

# pacstrap resolves the image against the offline repo and, with CacheDir on
# the mirror itself, extracts the package files in place instead of copying
# several GiB into a cache first (the same trick the installer's bind mount
# plays on the target).
image_pacman_conf="$build_cache_dir/pacman-root-image.conf"
sed "/^\[options\]/a CacheDir = /var/cache/omarchy/mirror/offline/" \
  "$build_cache_dir/pacman-offline.conf" >"$image_pacman_conf"

# The image ships as a plain file in the ISO9660 tree next to airootfs.sfs,
# not inside the squashfs: mkarchiso packs its work/iso directory as is, so a
# file seeded there ends up on the ISO with the boot records intact. Read
# straight off the boot medium it skips squashfs's per-block copy,
# mkarchiso no longer copies 3GB into the squashfs, and the
# image can be pulled out of the ISO with any ISO9660 tool. The live system
# finds it at /run/archiso/bootmnt/<install_dir>/<arch>/.
#
# profiledef.sh cannot be sourced standalone (its file_permissions needs
# mkarchiso's declare -A first); read install_dir from it. Its arch is
# "${OMARCHY_ARCH:-x86_64}", the architecture this build is for.
iso_subdir="$(sed -n 's/^install_dir="\(.*\)"$/\1/p' "$build_cache_dir/profiledef.sh")/$OMARCHY_ARCH"
[[ $iso_subdir == ?*/"$OMARCHY_ARCH" ]] || { echo "ERROR: could not read install_dir from profiledef.sh: '$iso_subdir'" >&2; exit 1; }
root_image_dir="$build_cache_dir/work/iso/$iso_subdir"
root_image="$root_image_dir/omarchy-root.img.zst"
mkdir -p "$root_image_dir"
# Builds from before the raw image left a send stream (and, briefly, its
# checksum) in the persistent build cache, where they would ship inside the
# squashfs.
rm -f "$build_cache_dir/airootfs/var/cache/omarchy/rootfs/omarchy-root.btrfs"*

image_localdb=/tmp/omarchy-root-image-localdb
echo "[timing] root image start $(date +%s)"
OMARCHY_IMAGE_LOCALDB_COPY="$image_localdb" \
  OMARCHY_RENAMED_PACKAGES="$renamed_list" OMARCHY_UNRESOLVED_PACKAGES="$unresolved_list" \
  bash /builder/build-root-image.sh "$image_pacman_conf" "$root_image" "${image_packages[@]}"
echo "[timing] root image end $(date +%s)"

# The installer verifies the image against this before it touches the disk
# (orchestrator prepare_install_target), so a truncated copy on a badly
# flashed USB fails the install while it is still free to fail. Next to the
# image, so it ships on the ISO beside it.
(cd "$root_image_dir" && sha256sum "${root_image##*/}" >"$root_image.sha256")

# Bound the boot-time hash: Type=oneshot units are exempt from systemd's
# default start timeout, so a stick that stalls reads instead of returning an
# error would hang omarchy-root-image-verify.service -- and with it the
# install -- forever. Budget a floor of 2 MiB/s over the image size (a USB 2.0
# port sustains ~30 MB/s; the margin covers the idle-class hash yielding to
# the live system's page-ins) plus ten minutes of slack for boot. On timeout
# systemd sets Result=timeout and omarchy-wait-root-image-verify turns that
# into a "medium too slow" message instead of the corrupt-medium one.
root_image_bytes=$(stat -c %s "$root_image")
verify_dropin_dir="$build_cache_dir/airootfs/etc/systemd/system/omarchy-root-image-verify.service.d"
mkdir -p "$verify_dropin_dir"
cat >"$verify_dropin_dir/50-size-timeout.conf" <<EOF
# Generated by build-iso.sh: 2 MiB/s floor over the $root_image_bytes-byte root image.
[Service]
TimeoutStartSec=$((root_image_bytes / (2 * 1024 * 1024) + 600))
EOF

# What the ISO ships out of this mirror. mkarchiso pacstraps the live root from
# the complete mirror at build time, but at install time only packages the
# root image does not already hold can ever be downloaded from it: the
# per-machine packages, and whatever omarchy-apply-system adds from
# omarchy-other.packages. So the live root's customize_airootfs.sh removes
# every package file the image already provides, at the same version, from
# its copy of the mirror. The repo db stays complete on purpose: the hardware
# scripts run `pacman -S --needed` over lists that mix packages the image has
# with ones it lacks, and pacman must still resolve every name, even the ones
# it then skips as up to date.
mirror_package_index() {
  bsdtar -xOf "$offline_mirror_dir/offline.db.tar.gz" --include='*/desc' |
    awk '/^%FILENAME%$/ { getline f } /^%NAME%$/ { getline n } /^%VERSION%$/ { getline v; print n "\t" v "\t" f }'
}
image_package_index() {
  local desc
  for desc in "$image_localdb"/local/*/desc; do
    awk '/^%NAME%$/ { getline n } /^%VERSION%$/ { getline v; print n "\t" v }' "$desc"
  done
}
#
# And of what the image lacks, only what an install can reach: the dependency
# closure of the names it can ask for. The rest is the live system's own
# tooling (about 180 packages, 125 MB), downloaded because
# the live root is pacstrapped from this mirror and then left in it.
if ! installable_files="$(
  pacman --config "$online_pacman_conf" --noconfirm \
    --dbpath /tmp/offlinedb -S --print --print-format '%f' "${target_packages[@]}"
)"; then
  echo "ERROR: could not resolve the packages an install can ask for" >&2
  exit 1
fi
shipped_list="$build_cache_dir/airootfs/usr/share/omarchy-iso/offline-mirror.shipped"
# archlinuxarm-keyring stays too, with its signature: on aarch64 validate_boot
# checks the target keyring against them (_validate_package_signing).
awk -F'\t' '
  FILENAME == ARGV[1] { installable[$1] = 1; next }
  FILENAME == ARGV[2] { image[$1 "\t" $2] = 1; next }
  (!(($1 "\t" $2) in image) && ($3 in installable)) || $1 == "archlinuxarm-keyring" { print $3 }
' <(printf '%s\n' "$installable_files") <(image_package_index) <(mirror_package_index) | sort -u >"$shipped_list"
# grep -c exits 1 on no match; the count check below wants the 0.
shipped_count=$(grep -c . "$shipped_list" || true)
mirror_count=$(mirror_package_index | wc -l)
if (( shipped_count == 0 || shipped_count >= mirror_count )); then
  echo "ERROR: the shipped-mirror selection looks wrong: $shipped_count of $mirror_count packages" >&2
  exit 1
fi
echo "Shipping $shipped_count of $mirror_count mirror packages; the root image provides the rest."

# The shipped mirror's own checksums, for omarchy-mirror-verify.service: the
# per-machine packages an install pacstraps from it are read off the medium
# like the root image, and a corrupt one would otherwise surface as a pacman
# error after the disk is gone. Its repo db rides along; pacman reads it too.
# So does every package's signature: on aarch64 validate_boot checks the
# target keyring against archlinuxarm-keyring's, after the disk is written
# (on x86_64 about 120 files, 32 KB in all).
mirror_files() {
  local file
  while IFS= read -r file; do
    echo "$file"
    [[ ! -f $file.sig ]] || echo "$file.sig"
  done <"$shipped_list"
  echo offline.db.tar.gz
}
mirror_sums="$build_cache_dir/airootfs/usr/share/omarchy-iso/offline-mirror.sha256"
(cd "$offline_mirror_dir" && mirror_files | xargs -d '\n' sha256sum) >"$mirror_sums"
mirror_bytes=$(cd "$offline_mirror_dir" && mirror_files | xargs -d '\n' stat -L -c %s | awk '{ s += $1 } END { print s }')
mirror_dropin_dir="$build_cache_dir/airootfs/etc/systemd/system/omarchy-mirror-verify.service.d"
mkdir -p "$mirror_dropin_dir"
printf '%s\n' "# Generated by build-iso.sh: 2 MiB/s floor over the $mirror_bytes bytes of the shipped mirror." \
  "[Service]" "TimeoutStartSec=$((mirror_bytes / (2 * 1024 * 1024) + 600))" >"$mirror_dropin_dir/50-size-timeout.conf"
echo "Mirror checksums: $(wc -l <"$mirror_sums") files, $((mirror_bytes >> 20)) MiB"

# Denominator for the install dashboard's progress bar: what the image holds
# plus the kernel's closure on top of it, resolved against the image's own
# local db with the pruned mirror, which is the question the installer's delta
# pacstrap asks. Plus one for the microcode package every real machine gets.
# phases.py records expected and actual in the timing JSON, so drift shows up
# in acceptance runs.
resolve_expected_packages() {
  # $1, if given: a platform's own default set, whose packages the installer
  # adds to the image's plain set on that platform.
  local base_list=${1:-}
  local resolve_root=/tmp/omarchy-expected-packages
  local image_count resolved
  # The kernel an install gets: --needed counts nothing for it while the
  # image carries it, and a kernel no install gets would count one more.
  local -a targets=("$OMARCHY_KERNEL")
  if [[ -n $base_list ]]; then
    mapfile -t -O 1 targets < <(
      grep -hv '^#\|^$' "$base_list" | grep -Fxv -f <(printf '%s\n' "${image_packages[@]}") || true
    )
  fi

  rm -rf "$resolve_root"
  mkdir -p "$resolve_root/var/lib/pacman"
  cp -a "$image_localdb/local" "$resolve_root/var/lib/pacman/"
  image_count=$(find "$resolve_root/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d | wc -l)

  pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -Sy >/dev/null || return 1

  # Capture before counting: no pipefail here, so a pacman failure inside a
  # pipeline would become a plausible partial count, which never trips the
  # dashboard's fallback.
  # pacman names the unsatisfied dependency on stdout, so show it on failure.
  if ! resolved="$(pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' --needed "${targets[@]}")"; then
    printf '%s\n' "$resolved" >&2
    return 1
  fi

  echo $(( image_count + $(printf '%s\n' "$resolved" | sort -u | grep -c .) + 1 ))
}

# Both failures are worth the build: -S --print only aborts when a target is
# missing from the offline repo, which would fail the delta pacstrap the same
# way, and the count is image packages plus the kernel closure, so one outside
# the plausible range means the root image itself is short of packages. (The
# dashboard falls back to a time-based curve without the file, but nothing
# else would catch a short image before an install.)
if ! expected_packages="$(resolve_expected_packages)"; then
  echo "ERROR: could not resolve the target package count from the offline mirror." >&2
  echo "       pacman -S --print aborts the whole transaction if any single target" >&2
  echo "       is missing, so this almost certainly means the installer's delta" >&2
  echo "       pacstrap would fail the same way." >&2
  exit 1
fi
if (( expected_packages < 600 || expected_packages > 2000 )); then
  echo "ERROR: resolved target package count $expected_packages is outside the" >&2
  echo "       expected 600-2000 range. The count is the image's package count" >&2
  echo "       plus the kernel closure, so this means the root image is short." >&2
  exit 1
fi
printf '%s\n' "$expected_packages" \
  >"$build_cache_dir/airootfs/usr/share/omarchy-iso/expected-packages"
echo "Target install resolves to $expected_packages packages."

# One count for each platform's own default set (aarch64 boards), which the
# dashboard picks on that platform (phases._expected_package_count).
for platform_list in "$build_cache_dir"/airootfs/usr/share/omarchy-iso/omarchy-base.*.packages; do
  [[ -f $platform_list ]] || continue
  platform=${platform_list##*/omarchy-base.}
  platform=${platform%.packages}
  if ! expected_packages="$(resolve_expected_packages "$platform_list")"; then
    echo "ERROR: could not resolve the target package count for $platform from the offline mirror." >&2
    exit 1
  fi
  printf '%s\n' "$expected_packages" \
    >"$build_cache_dir/airootfs/usr/share/omarchy-iso/expected-packages.$platform"
  echo "Target install on $platform resolves to $expected_packages packages."
done

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO. profiledef.sh reads OMARCHY_ARCH for the archiso arch/bootmodes.
echo "[timing] mkarchiso start $(date +%s)"
"$mkarchiso_command" -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"
echo "[timing] mkarchiso end $(date +%s)"

# The live initramfs must stay small enough for GRUB and the kernel to place
# it. omarchy-iso#128: at 241 MiB (every DRM driver's firmware, via the kms
# hook) GRUB could not allocate it on a Lenovo Yoga's EFI memory map and booted
# the kernel without it; measured under OVMF it needs 1 GB of RAM where the
# 91 MiB one boots in 512 MB. 128 MiB leaves headroom over today's size and
# none for that class of regression.
live_initramfs_limit=$((128 * 1024 * 1024))
for live_initramfs in "$build_cache_dir/work/iso/${iso_subdir%/*}/boot/$OMARCHY_ARCH"/initramfs-*.img; do
  [[ -f $live_initramfs ]] || { echo "ERROR: no live initramfs under work/iso/${iso_subdir%/*}/boot/$OMARCHY_ARCH" >&2; exit 1; }
  live_initramfs_bytes=$(stat -c %s "$live_initramfs")
  echo "live initramfs $(basename "$live_initramfs"): $live_initramfs_bytes bytes"
  if (( live_initramfs_bytes > live_initramfs_limit )); then
    echo "ERROR: live initramfs is $live_initramfs_bytes bytes, over the $live_initramfs_limit limit (omarchy-iso#128)" >&2
    exit 1
  fi
done

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
