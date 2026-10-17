#!/bin/bash

set -e

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"
OMARCHY_ARCH="${OMARCHY_ARCH:-x86_64}"
OMARCHY_KERNEL="${OMARCHY_KERNEL:-linux-t2}"
# profiledef.sh reads both in the mkarchiso environment.
export OMARCHY_ARCH OMARCHY_KERNEL

source /builder/node-release.sh
source /builder/arm64-kernel-image.sh
source /builder/archiso-aarch64-mkinitcpio.sh
source /builder/grub-platform.sh

# The online pacman configuration drives every package download below. On
# aarch64 it points at Omarchy's edge aarch64 repository and Arch Linux ARM,
# and at a package bundle mounted at /packages first when there is one.
case "$OMARCHY_ARCH" in
  x86_64)
    online_pacman_conf="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
    ;;
  aarch64)
    online_pacman_conf=/configs/pacman-online-aarch64.conf
    # One image serves every board, on one kernel.
    if [[ $OMARCHY_KERNEL != linux-omarchy ]]; then
      echo "ERROR: aarch64 builds boot linux-omarchy (got '$OMARCHY_KERNEL')" >&2
      exit 1
    fi
    if [[ -d /packages && ! -f /packages/SHA256SUMS ]]; then
      echo "ERROR: the package bundle mounted at /packages needs a SHA256SUMS" >&2
      exit 1
    fi
    if [[ $OMARCHY_MIRROR != edge ]]; then
      echo "ERROR: aarch64 builds use the edge channel, the only one Omarchy publishes for aarch64 (got '$OMARCHY_MIRROR')" >&2
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
if [[ $OMARCHY_ARCH == aarch64 ]]; then
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
    sed "s|^Server = file:///packages$|Server = file://$bundle_index|" /configs/pacman-online-aarch64.conf > "$online_pacman_conf"
  else
    # No bundle, so no [platform] repo: pacman refuses a repo it cannot sync.
    awk '/^\[platform\]$/ { skip = 1; next } /^\[/ { skip = 0 } !skip' \
      /configs/pacman-online-aarch64.conf > "$online_pacman_conf"
  fi

  # The container image arrives pointed at Arch Linux ARM's own mirrors. Its
  # packages come from the same place the ISO's do: Omarchy's mirror of them.
  awk '/^\[core\]$/ { getline server; print server; exit }' "$online_pacman_conf" >/etc/pacman.d/mirrorlist
  grep -q '^Server = https://[a-z-]*mirror\.omarchy\.org/' /etc/pacman.d/mirrorlist || {
    echo "ERROR: no Omarchy mirror for [core] in $online_pacman_conf" >&2
    exit 1
  }
  pacman --noconfirm -Sy archlinuxarm-keyring
  pacman-key --populate archlinuxarm
  # Arch Linux ARM does not publish archiso. Install its runtime dependencies
  # and run the repository's pinned submodule copy, patched for arm64-efi GRUB.
  pacman --noconfirm -Syu \
    arch-install-scripts dosfstools e2fsprogs erofs-utils libarchive libisoburn \
    mtools squashfs-tools git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli
  mkarchiso_command=/tmp/mkarchiso-aarch64
  cp /archiso/archiso/mkarchiso "$mkarchiso_command"
  patch --batch --forward --fuzz=0 "$mkarchiso_command" </builder/archiso-v87-aarch64-grub.patch
  # A Snapdragon laptop boots the live system from a UKI built into /boot;
  # carry it onto the ISO beside the kernel when the build made one.
  patch --batch --forward --fuzz=0 "$mkarchiso_command" </builder/archiso-v87-aarch64-boot-efi.patch
  chmod 0755 "$mkarchiso_command"
else
  pacman --noconfirm -Sy archlinux-keyring
  # Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
  # so this container can be months behind the mirror it installs from. A plain
  # -Sy install is then a partial upgrade — new packages linked against a glibc
  # the container doesn't have yet.
  pacman --noconfirm -Syu archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli
  mkarchiso_command=mkarchiso
fi

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

# Architecture overlay on the shared profile: live kernel, initramfs hooks,
# GRUB entries. x86_64 keeps its exact previous behaviour.
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
  # The shared image needs A16's dynamically requested GPU firmware too;
  # the live preset's -c archiso.conf bypasses the other drop-ins.
  cat /builder/a16-gpu-firmware.conf >> "$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  boot_splash_kernel_options="quiet splash "
  cp "/builder/${OMARCHY_KERNEL}.preset" "$build_cache_dir/airootfs/etc/mkinitcpio.d/${OMARCHY_KERNEL}.preset"
  # The N1x firmware's SPCR serial console would take the console from the
  # panel, hence console=tty0 acpi=nospcr.
  kernel_options="console=tty0 acpi=nospcr initramfs_async=0"
  # Snapdragon firmware hands the kernel no device tree. Once the live kernel
  # and initramfs exist, wrap them in a UKI that carries the device trees the
  # kernel package ships; GRUB chainloads it where there is one
  # (configs/grub/grub.cfg).
  install -Dm0644 /builder/qualcomm/live-uki.sh "$build_cache_dir/airootfs/root/qualcomm-live-uki.sh"
  cat >"$build_cache_dir/airootfs/root/customize_airootfs.sh" <<CUSTOMIZE
#!/bin/bash
set -euo pipefail
bash /root/qualcomm-live-uki.sh $OMARCHY_KERNEL
rm -f /root/qualcomm-live-uki.sh
CUSTOMIZE
  chmod 0755 "$build_cache_dir/airootfs/root/customize_airootfs.sh"
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
  kernel_options="xe.enable_panel_replay=0 initramfs_async=0"
fi
for grub_config in "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"; do
  configure_grub_kernel "$grub_config" "$OMARCHY_KERNEL"
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
fi
{
  echo "debug=${OMARCHY_INSTALL_DEBUG:-0}"
  echo "built_at=$(date -Is)"
  echo "ref=$OMARCHY_ISO_REF"
  echo "omarchy_iso_commit=${OMARCHY_ISO_COMMIT:-unknown}"
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

# When --local-source is in effect, build omarchy* from the mounted source
# trees and drop them in the offline mirror. Otherwise pacman -Syw below
# downloads the published versions from the omarchy network mirror.
if [[ -d /omarchy-source && -d /omarchy-pkgs ]]; then
  bash /builder/build-omarchy-packages.sh "$offline_mirror_dir"
  LOCAL_OMARCHY_BUILD=1

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

# Node.js binary for offline mise install, matched to the target architecture.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
node_platform=linux-x64
[[ $OMARCHY_ARCH == aarch64 ]] && node_platform=linux-arm64
if ! IFS=$'\t' read -r NODE_FILENAME NODE_SHA < <(select_node_release "$node_platform" <<<"$NODE_SHASUMS"); then
  echo "ERROR: could not find Node.js $node_platform release metadata" >&2
  exit 1
fi
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  # Plymouth stays out of the live initramfs (archiso-aarch64-mkinitcpio.sh);
  # openssh and pciutils serve the recovery entry and remote debugging.
  # For the Snapdragon laptops: ukify builds the live UKI, and the installer
  # saves a laptop's signed firmware from Windows with qcom-firmware-extract.
  arch_packages=("$OMARCHY_KERNEL" archlinuxarm-keyring git gum jq openssl openssh pciutils plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted systemd-ukify linux-firmware-qcom qcom-firmware-extract asus-zenbook-a16-firmware python)
else
  arch_packages=(linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)
fi
live_packages_file="$build_cache_dir/packages.$OMARCHY_ARCH"
printf '%s\n' "${arch_packages[@]}" >> "$live_packages_file"

# The live ISO boots linux-t2 (see airootfs/etc/mkinitcpio.d/linux-t2.preset), so
# stock linux is a second kernel nobody boots: ~147MB of ISO, plus its own archiso
# initramfs, copied into both the ISO tree and the size-constrained FAT EFI image.
#
# It cannot just be deleted — releng's broadcom-wl hard-depends on it, and it is
# the only releng package that does, so pacman would drag the kernel straight back
# in. broadcom-wl is a prebuilt module for stock linux and cannot load on the
# kernel we boot, so it has done nothing since we started booting T2 anyway. The
# install is entirely offline and the live environment needs no Wi-Fi driver.
#
# Anchored so linux-t2 and linux-firmware are untouched.
sed -i -E '/^(linux|broadcom-wl)$/d' "$live_packages_file"

# Build the offline mirror: everything pacstrap might want during the target
# install. With --local-source, the omarchy* packages we just built are
# already in the mirror and we filter them out below. Without it, pacman -Syw
# pulls the published omarchy* from the network mirror like any other package.
if [[ -d /omarchy-source ]]; then
  base_pkg_lists=(/omarchy-source/install/omarchy-base.packages /omarchy-source/install/omarchy-other.packages)
  setup_form=/omarchy-source/install/provisioning/setup-form.sh
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

# Collect every package we want available in the offline mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    cat "$live_packages_file"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}" "${platform_lists[@]}"
    grep -hv '^#\|^$' /builder/archinstall.packages
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
# arch-mact2 dropped apple-bcm-firmware on 2026-09-16 in favour of
# apple-bcm-firmware-fetcher, which does the same job (pull the T2 Wi-Fi and
# Bluetooth firmware off the macOS volume) but only conflicts with the old name
# rather than replacing it, so pacman cannot follow the rename on its own.
mapfile -t all_packages < <(
  printf '%s\n' "${all_packages[@]}" |
    sed -e 's/^broadcom-wl$/broadcom-wl-dkms/' \
      -e 's/^apple-bcm-firmware$/apple-bcm-firmware-fetcher/' |
    sort -u
)

# x86_64: Omarchy's optional list also names firmware for aarch64 boards,
# which has no x86_64 build. Each exclusion is explicit and printed.
if [[ $OMARCHY_ARCH == x86_64 ]]; then
  aarch64_only=(asus-proart-p14-speaker-firmware)
  printf 'x86_64: excluding aarch64-only package %s\n' "${aarch64_only[@]}" >&2
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | grep -Fxv -f <(printf '%s\n' "${aarch64_only[@]}"))
fi

# aarch64: the Omarchy manifests are written for x86_64 machines. Swap the
# kernel for the platform kernel and drop packages that only exist for x86.
# Every exclusion is explicit and printed; anything else missing from the
# mirror still fails the build below.
if [[ $OMARCHY_ARCH == aarch64 ]]; then
  source /builder/aarch64-package-filter.sh
  mapfile -t all_packages < <(filter_aarch64_packages "$OMARCHY_KERNEL" "${all_packages[@]}")
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
fi

mkdir -p /tmp/offlinedb
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

# Resolve the exact filenames chosen by the same synced package databases used
# for the download. Pruning by this transaction (rather than merely keeping the
# newest version of every cached package name) removes packages that have left
# the lists or dependency closure, such as an old Electron major version.
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

# Rebuild the offline repo db from scratch so size/checksum/depends entries
# always reflect only the package files selected for this build.
# Every package archive in the mirror, indexed by one repo-add per CPU: one
# alone hashes and lists a thousand packages one after another. On aarch64 the
# mirror also holds the bundle's .pkg.tar.xz archives.
bash /builder/index-offline-mirror.sh "$offline_mirror_dir"

# mkarchiso expects the mirror at /var/cache/omarchy/mirror/offline inside the
# container (the airootfs path); symlink rather than duplicate.
mkdir -p /var/cache/omarchy/mirror
ln -sf "$offline_mirror_dir" /var/cache/omarchy/mirror/offline

# Denominator for the install dashboard's progress bar. Resolving the mirror's
# own package lists against the mirror we just indexed, with an empty local db,
# is the question pacstrap asks at install time — same resolver, same repo, same
# lists — so no hand-kept constant can drift.
#
# It over-counts by ~1 in 925: archinstall.packages lists both amd-ucode and
# intel-ucode because the mirror must contain either. phases.py records expected
# and actual in the timing JSON, so growing drift shows up in acceptance runs.
# The early-bootstrap set is already inside this closure, so restating it would
# only add a second list to drift.
resolve_expected_packages() {
  local base_list=$1
  local resolve_root=/tmp/omarchy-expected-packages
  local resolved
  local -a targets

  rm -rf "$resolve_root"
  mkdir -p "$resolve_root/var/lib/pacman"

  mapfile -t targets < <(
    {
      grep -hv '^#\|^$' "$archinstall_packages_file"
      # Read the shipped copy, which is what _runtime_package_list reads at
      # install time, not the build-time source it came from.
      grep -hv '^#\|^$' "$base_list"
      printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" \
        "$OMARCHY_NVIM_PACKAGE"
    } | sort -u
  )

  pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -Sy >/dev/null || return 1

  # Capture before counting: no pipefail here, so a pacman failure inside a
  # pipeline would become a plausible partial count, which never trips the
  # dashboard's fallback.
  # pacman names the unsatisfied dependency on stdout, so show it on failure.
  if ! resolved="$(pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' "${targets[@]}")"; then
    printf '%s\n' "$resolved" >&2
    return 1
  fi

  printf '%s\n' "$resolved" | sort -u | grep -c .
}

# Worth failing the build over: -S --print only aborts when a target is missing
# from the offline repo, which would fail pacstrap the same way. A count that
# merely looks wrong is not — the dashboard falls back without the file.
#
# One denominator for each default set the installer can pick: the plain one,
# and on aarch64 each platform's, so a platform whose packages the mirror lacks
# stops the build here and not an install on that platform.
for base_list in "$build_cache_dir"/airootfs/usr/share/omarchy-iso/omarchy-base*.packages; do
  expected_file=${base_list##*/omarchy-base}
  expected_file=expected-packages${expected_file%.packages}
  if ! expected_packages="$(resolve_expected_packages "$base_list")"; then
    echo "ERROR: could not resolve the target package count for ${base_list##*/} from the offline mirror." >&2
    echo "       pacman -S --print aborts the whole transaction if any single target" >&2
    echo "       is missing, so this almost certainly means pacstrap would fail the" >&2
    echo "       same way at install time." >&2
    exit 1
  fi
  if (( expected_packages < 600 || expected_packages > 2000 )); then
    echo "WARNING: resolved target package count $expected_packages for ${base_list##*/} is outside" >&2
    echo "         the expected 600-2000 range; shipping no denominator so the install" >&2
    echo "         dashboard falls back to its time-based curve." >&2
  else
    printf '%s\n' "$expected_packages" \
      >"$build_cache_dir/airootfs/usr/share/omarchy-iso/$expected_file"
    echo "Target install from ${base_list##*/} resolves to $expected_packages packages."
  fi
done

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO. profiledef.sh reads OMARCHY_ARCH for the archiso arch/bootmodes.
"$mkarchiso_command" -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
