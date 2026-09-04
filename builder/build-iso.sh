#!/bin/bash

set -e

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"

# Build for the host architecture.
case "$(uname -m)" in
  aarch64)
    ISO_ARCH=aarch64
    ISO_NODE_ARCH=arm64
    ISO_KERNEL=linux-aarch64
    ;;
  *)
    ISO_ARCH=x86_64
    ISO_NODE_ARCH=x64
    ISO_KERNEL=linux-t2
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

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
# Restore Arch Linux ARM trust after initializing the container keyring.
if pacman -Q archlinuxarm-keyring &>/dev/null; then
  pacman-key --populate archlinuxarm
fi
pacman --noconfirm -Sy archlinux-keyring
# Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
# so this container can be months behind the mirror it installs from. A plain
# -Sy install is then a partial upgrade — new packages linked against a glibc
# the container doesn't have yet.
pacman --noconfirm -Syu git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli

# Arch Linux ARM requires the vendored archiso fallback.
if ! pacman --noconfirm -S --needed archiso; then
  echo "archiso package unavailable; installing from the vendored submodule"
  # Dependencies normally installed with the archiso package.
  pacman --noconfirm -S --needed \
    squashfs-tools dosfstools mtools libisoburn erofs-utils arch-install-scripts e2fsprogs
  # Build only scripts and profiles from the read-only submodule.
  cp -r /archiso /tmp/archiso-src
  # Filter GRUB modules that are unavailable for arm64-efi.
  patch -d /tmp/archiso-src -p1 --forward --batch \
    </builder/patches/archiso-grubmodules.patch || true
  # Copy the DTB-carrying UKI from /boot into the ISO.
  patch -d /tmp/archiso-src -p1 --forward --batch \
    </builder/patches/archiso-copy-boot-efi.patch || true
  make -C /tmp/archiso-src PREFIX=/usr install-scripts install-profiles
fi
command -v mkarchiso

# Verify the required aarch64 archiso patches are present.
if [[ $ISO_ARCH == aarch64 ]] && ! grep -q _filter_grubmodules "$(command -v mkarchiso)"; then
  echo "This mkarchiso hardcodes a GRUB module list that includes modules not" >&2
  echo "built for arm64-efi (at_keyboard, keylayouts, usb, usbserial_*), so" >&2
  echo "grub-mkstandalone would abort. Apply builder/patches/archiso-grubmodules.patch" >&2
  echo "or use an archiso that already filters the list." >&2
  exit 1
fi
if [[ $ISO_ARCH == aarch64 ]] && ! grep -q 'Unified kernel images built into /boot' "$(command -v mkarchiso)"; then
  echo "This mkarchiso does not copy the DTB-carrying live UKI out of /boot." >&2
  echo "Apply builder/patches/archiso-copy-boot-efi.patch before installing it." >&2
  exit 1
fi

# Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
# during the build without keyserver lookups).
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# omarchy-keyring is needed inside the offline mirror too.
# Remove x86-only repositories and mirror overrides from the aarch64 config.
PACMAN_ONLINE_CONF="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
if [[ $ISO_ARCH == aarch64 ]]; then
  PACMAN_ONLINE_CONF="/tmp/pacman-online-${OMARCHY_MIRROR}.conf"
  awk '
    /^\[multilib\]$/   { skip = 1; next }
    /^\[arch-mact2\]$/ { skip = 1; next }
    /^\[/               { skip = 0; section = $0 }
    skip                 { next }
    (section == "[core]" || section == "[extra]") && /^Server[[:space:]]*=/ { next }
    { print }
  ' "/configs/pacman-online-${OMARCHY_MIRROR}.conf" > "$PACMAN_ONLINE_CONF"
  echo "aarch64: staged $PACMAN_ONLINE_CONF without [multilib]/[arch-mact2]"
fi

# Replace the published Omarchy repository with the mounted local repository.
if [[ -d /omarchy-repo ]]; then
  if [[ $PACMAN_ONLINE_CONF == /configs/* ]]; then
    cp "$PACMAN_ONLINE_CONF" "/tmp/pacman-online-${OMARCHY_MIRROR}.conf"
    PACMAN_ONLINE_CONF="/tmp/pacman-online-${OMARCHY_MIRROR}.conf"
  fi
  sed -i '/^\[omarchy\]$/,/^$/ s|^Server = .*|Server = file:///omarchy-repo|' "$PACMAN_ONLINE_CONF"
  echo "local repo: [omarchy] served from file:///omarchy-repo"
  ls /omarchy-repo/omarchy.db >/dev/null
fi

pacman --config $PACMAN_ONLINE_CONF --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Append the [omarchy] repo to the container's /etc/pacman.conf so subsequent
# tools (notably makepkg in build-omarchy-packages.sh) can resolve omarchy-
# only build deps like limine-snapper-sync and limine-mkinitcpio-hook.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
  awk '/^\[omarchy\]/,/^$/' $PACMAN_ONLINE_CONF >> /etc/pacman.conf
fi

# Build locations
build_cache_dir=/var/cache

# Packages unavailable or inapplicable on aarch64.
OMARCHY_ARCH_DROP=(
  # x86 platform hardware
  amd-ucode intel-ucode
  apple-bcm-firmware apple-t2-audio-config t2fanrd linux-t2 linux-t2-headers
  macbook12-spi-driver-dkms macbook8-spi-pxa2xx-nodma-dkms
  asusctl supergfxctl rog-control-center
  dell-xps-touchpad-haptics tuxedo-drivers-nocompatcheck-dkms
  intel-ipu7-camera intel-lpmd intel-media-driver libva-intel-driver
  thermald linux-ptl linux-ptl-headers vpl-gpu-rt libvpl
  vulkan-intel vulkan-radeon
  nvidia-dkms nvidia-open-dkms nvidia-utils nvidia-580xx-dkms nvidia-580xx-utils
  libva-nvidia-driver lib32-nvidia-utils lib32-nvidia-580xx-utils
  broadcom-wl yt6801-dkms qmk-hid xpadneo-dkms
  edk2-shell memtest86+ memtest86+-efi syslinux refind

  # x86 virtualization guests
  hyperv open-vm-tools virtualbox-guest-utils-nox qemu-user-static-binfmt

  # Software without an aarch64 build
  obs-studio obsidian pinta dotnet-runtime asdcontrol

  # Build artifacts not carried by Arch Linux ARM
  yay-debug reflector
)

# Use equivalent packages available on aarch64.
OMARCHY_ARCH_SUBST_FROM=(quickshell-git mise)
OMARCHY_ARCH_SUBST_TO=(quickshell mise-bin)
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

# Point every GRUB path at the selected live kernel.
for _grub_cfg in "$build_cache_dir"/grub/*.cfg; do
  [[ -e $_grub_cfg ]] || continue
  sed -i \
    -e "s|vmlinuz-linux-t2|vmlinuz-${ISO_KERNEL}|g" \
    -e "s|initramfs-linux-t2\\.img|initramfs-${ISO_KERNEL}.img|g" \
    "$_grub_cfg"
done

# Stage aarch64 initramfs and UKI setup before pacstrap runs mkinitcpio.
if [[ $ISO_ARCH == aarch64 ]]; then
  install -Dm644 /configs/aarch64/zz-aarch64-live.conf \
    "$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/zz-aarch64-live.conf"
  install -Dm644 /configs/aarch64/linux.preset \
    "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset"
  install -Dm755 /configs/aarch64/customize_airootfs.sh \
    "$build_cache_dir/airootfs/root/customize_airootfs.sh"
  install -Dm755 /configs/aarch64/live-uki.sh \
    "$build_cache_dir/airootfs/root/live-uki.sh"
  # The T2 kernel image is absent on aarch64.
  rm -f "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset"
  echo "aarch64: staged live-ISO mkinitcpio overrides"
fi
# configs/aarch64/ is a staging directory, not part of the airootfs.
rm -rf "$build_cache_dir/aarch64"
mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"
echo "$OMARCHY_ISO_REF" > "$build_cache_dir/airootfs/root/omarchy_iso_ref"
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
fi

# Node.js binary for offline mise install.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-${ISO_NODE_ARCH}.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-${ISO_NODE_ARCH}.tar.gz" | awk '{print $1}')
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
arch_packages=("$ISO_KERNEL" git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >> "$build_cache_dir/packages.$ISO_ARCH"

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
_drop_re='^(linux|broadcom-wl)$'
# Arch Linux ARM's releng list also includes linux-firmware-marvell.
[[ $ISO_ARCH == aarch64 ]] && _drop_re='^(linux|linux-firmware-marvell|broadcom-wl)$'
sed -i -E "/$_drop_re/d" "$build_cache_dir/packages.$ISO_ARCH"

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
  pacman --config $PACMAN_ONLINE_CONF --noconfirm -Syw "$OMARCHY_RUNTIME_PACKAGE" --cachedir "$bootstrap_cache_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
  omarchy_pkg=$(find "$bootstrap_cache_dir" -maxdepth 1 -type f \( -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.zst" -o -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.xz" \) | sort | head -1)
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
fi

mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
cp "${base_pkg_lists[0]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
cp "${base_pkg_lists[1]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-other.packages"

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

# Apply the aarch64 filter to every package list shipped on the ISO.
filter_shipped_package_list() {
  local file="$1" tmp
  [[ -f $file ]] || return 0
  tmp="$(mktemp)"
  local line kept=0 dropped=0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ -z $line || $line == \#* ]]; then printf '%s\n' "$line" >>"$tmp"; continue; fi
    local skip=""
    for d in "${OMARCHY_ARCH_DROP[@]}"; do [[ $line == "$d" ]] && { skip=1; break; }; done
    if [[ -n $skip ]]; then dropped=$((dropped+1)); continue; fi
    for i in "${!OMARCHY_ARCH_SUBST_FROM[@]}"; do
      [[ $line == "${OMARCHY_ARCH_SUBST_FROM[$i]}" ]] && line="${OMARCHY_ARCH_SUBST_TO[$i]}"
    done
    printf '%s\n' "$line" >>"$tmp"; kept=$((kept+1))
  done <"$file"
  mv "$tmp" "$file"
  echo "aarch64: $(basename "$file"): kept $kept, dropped $dropped"
}

if [[ $(uname -m) == aarch64 ]]; then
  ARCHINSTALL_PACKAGES="$build_cache_dir/builder/archinstall.packages"
  # mkarchiso installs this list directly into the live environment.
  filter_shipped_package_list "$build_cache_dir/packages.$ISO_ARCH"
  filter_shipped_package_list "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
  filter_shipped_package_list "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-other.packages"
  # Filter a writable copy of the mounted archinstall package list.
  mkdir -p "$build_cache_dir/builder"
  cp /builder/archinstall.packages "$build_cache_dir/builder/archinstall.packages"
  filter_shipped_package_list "$build_cache_dir/builder/archinstall.packages"
fi

# Collect every package we want available in the offline mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    # Strip comments and blank lines from every package list.
    grep -hv '^#\|^$' "$build_cache_dir/packages.$ISO_ARCH"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}"
    grep -hv '^#\|^$' "${ARCHINSTALL_PACKAGES:-/builder/archinstall.packages}"
    # Always include the selected Omarchy packages so the target install can
    # find the runtime and companion packages in the offline mirror.
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u
)

if [[ $(uname -m) == aarch64 ]]; then
  declare -a _kept=() _dropped=()
  for _p in "${all_packages[@]}"; do
    _skip=""
    for _d in "${OMARCHY_ARCH_DROP[@]}"; do
      [[ $_p == "$_d" ]] && { _skip=1; break; }
    done
    if [[ -n $_skip ]]; then _dropped+=("$_p"); continue; fi
    for _i in "${!OMARCHY_ARCH_SUBST_FROM[@]}"; do
      if [[ $_p == "${OMARCHY_ARCH_SUBST_FROM[$_i]}" ]]; then
        _p="${OMARCHY_ARCH_SUBST_TO[$_i]}"
        echo "aarch64: substituting ${OMARCHY_ARCH_SUBST_FROM[$_i]} -> $_p"
      fi
    done
    _kept+=("$_p")
  done
  mapfile -t all_packages < <(printf '%s\n' "${_kept[@]}" | sort -u)
  echo "aarch64: dropped ${#_dropped[@]} package(s) with no aarch64 build:"
  printf '  %s\n' "${_dropped[@]}"
  echo "aarch64: ${#all_packages[@]} package(s) remain for the offline mirror"
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
  pacman --config $PACMAN_ONLINE_CONF --noconfirm -Syw \
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
  pacman --config "$PACMAN_ONLINE_CONF" --noconfirm \
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

# Keep packages used only by post-install hooks in the offline mirror.
require_offline_package() {
  local required_name="$1" package_file package_name

  for package_file in "$offline_mirror_dir/"*.pkg.tar.zst "$offline_mirror_dir/"*.pkg.tar.xz; do
    [[ -f $package_file ]] || continue
    read -r package_name _ < <(pacman -Qp "$package_file" 2>/dev/null) || continue
    [[ $package_name == "$required_name" ]] && return 0
  done

  echo "ERROR: offline mirror is missing post-install package: $required_name" >&2
  return 1
}

if [[ $ISO_ARCH == aarch64 ]]; then
  require_offline_package archlinuxarm-keyring
fi

# Rebuild the offline repo db from scratch so size/checksum/depends entries
# always reflect only the package files selected for this build.
rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
# Avoid passing an unmatched package format glob to repo-add.
offline_repo_packages=()
for package_file in "$offline_mirror_dir/"*.pkg.tar.zst "$offline_mirror_dir/"*.pkg.tar.xz; do
  [[ -e $package_file ]] || continue
  offline_repo_packages+=("$package_file")
done
if (( ${#offline_repo_packages[@]} == 0 )); then
  echo "ERROR: no package files found in $offline_mirror_dir" >&2
  exit 1
fi
repo-add "$offline_mirror_dir/offline.db.tar.gz" "${offline_repo_packages[@]}"

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
  local resolve_root=/tmp/omarchy-expected-packages
  local resolved
  local -a targets

  rm -rf "$resolve_root"
  mkdir -p "$resolve_root/var/lib/pacman"

  mapfile -t targets < <(
    {
      grep -hv '^#\|^$' "${ARCHINSTALL_PACKAGES:-/builder/archinstall.packages}"
      # Read the shipped copy, which is what _runtime_package_list reads at
      # install time, not the build-time source it came from.
      grep -hv '^#\|^$' \
        "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
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
  resolved="$(pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' "${targets[@]}")" || return 1

  printf '%s\n' "$resolved" | sort -u | grep -c .
}

# Worth failing the build over: -S --print only aborts when a target is missing
# from the offline repo, which would fail pacstrap the same way. A count that
# merely looks wrong is not — the dashboard falls back without the file.
if ! expected_packages="$(resolve_expected_packages)"; then
  echo "ERROR: could not resolve the target package count from the offline mirror." >&2
  echo "       pacman -S --print aborts the whole transaction if any single target" >&2
  echo "       is missing, so this almost certainly means pacstrap would fail the" >&2
  echo "       same way at install time." >&2
  exit 1
fi
if (( expected_packages < 600 || expected_packages > 2000 )); then
  echo "WARNING: resolved target package count $expected_packages is outside the" >&2
  echo "         expected 600-2000 range; shipping no denominator so the install" >&2
  echo "         dashboard falls back to its time-based curve." >&2
else
  printf '%s\n' "$expected_packages" \
    >"$build_cache_dir/airootfs/usr/share/omarchy-iso/expected-packages"
  echo "Target install resolves to $expected_packages packages."
fi

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO.
mkarchiso -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
