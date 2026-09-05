#!/bin/bash

set -e

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"

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

: "${OMARCHY_ARCH:=x86_64}"
export OMARCHY_ARCH

# aarch64 pulls its base from Arch Linux ARM, whose repo set and directory layout
# both differ from Arch's, so it gets its own pacman configs rather than the
# x86_64 ones aimed at another host.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  pacman_online_conf="/configs/aarch64/pacman-online-${OMARCHY_MIRROR}.conf"
else
  pacman_online_conf="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
fi

# The tracked configs name the public mirrors. OMARCHY_PKGS_MIRROR and
# OMARCHY_BASE_MIRROR retarget them per build, so pointing at a different package
# repo needs no edit to a tracked file -- necessary while pkgs.omarchy.org
# publishes no aarch64 tree, and useful afterwards for anyone self-hosting.
# /configs is mounted read-only, so the override lands on a writable copy.
if [[ -n ${OMARCHY_PKGS_MIRROR:-} || -n ${OMARCHY_BASE_MIRROR:-} ]]; then
  cp "$pacman_online_conf" /tmp/pacman-online.conf
  [[ -n ${OMARCHY_PKGS_MIRROR:-} ]] &&
    sed -i "s|^Server = https://pkgs\.omarchy\.org/.*|Server = ${OMARCHY_PKGS_MIRROR}|" /tmp/pacman-online.conf
  if [[ -n ${OMARCHY_BASE_MIRROR:-} ]]; then
    # Replace the complete global fallback set with exactly one pinned server
    # in each ALARM base repo. Matching hostnames is insufficient now that the
    # defaults intentionally span archlinuxarm.org and independent HTTPS hosts.
    awk -v server="$OMARCHY_BASE_MIRROR" '
      /^\[(core|extra|alarm)\]$/ {
        in_base = 1
        print
        print "Server = " server
        next
      }
      /^\[/ { in_base = 0 }
      in_base && /^Server = / { next }
      { print }
    ' /tmp/pacman-online.conf > /tmp/pacman-online.conf.pinned
    mv /tmp/pacman-online.conf.pinned /tmp/pacman-online.conf
  fi
  pacman_online_conf=/tmp/pacman-online.conf
  echo "Mirror overrides applied:"
  grep -E '^\[|^Server' /tmp/pacman-online.conf | sed 's/^/  /'
fi

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
# Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
# so this container can be months behind the mirror it installs from. A plain
# -Sy install is then a partial upgrade — new packages linked against a glibc
# the container doesn't have yet.
#
# Arch Linux ARM does not package archiso. The submodule this repo already pins
# ships mkarchiso itself, so aarch64 installs what that script calls out to and
# runs the vendored copy. mkinitcpio-archiso is a separate package and is the
# part that matters most: it provides the archiso* mkinitcpio hooks the live
# initramfs is built from, and it IS in ALARM.
build_tools=(git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli)
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  build_tools+=(mkinitcpio-archiso arch-install-scripts squashfs-tools libisoburn mtools dosfstools erofs-utils)
else
  build_tools+=(archiso)
fi

# makepkg runs with --nodeps, so whatever OMARCHY_EXTRA_PKGBUILDS needs in order
# to build has to already be in the container. The current extras (tzupdate,
# tensaku, hyprland-preview-share-picker) are all Rust. Extras needing another
# toolchain will need it added here.
if [[ -n ${OMARCHY_EXTRA_PKGBUILDS:-} ]]; then
  build_tools+=(rust)
fi
pacman --noconfirm -Syu "${build_tools[@]}"

# Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
# during the build without keyserver lookups).
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# omarchy-keyring is needed inside the offline mirror too.
pacman --config "$pacman_online_conf" --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Prepend the [omarchy] repo to the container's /etc/pacman.conf so subsequent
# tools (notably makepkg in build-omarchy-packages.sh) can resolve Omarchy-only
# build deps and compatibility overrides. Repository order is package priority
# in pacman; appending this section would silently select a broken ALARM package
# with the same name instead of the tested overlay version.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
  {
    awk '/^\[omarchy\]$/,/^$/' "$pacman_online_conf"
    cat /etc/pacman.conf
  } >/tmp/pacman.conf.with-omarchy
  install -m 0644 /tmp/pacman.conf.with-omarchy /etc/pacman.conf
fi

# Build locations
build_cache_dir=/var/cache
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$build_cache_dir" "$offline_mirror_dir"

# Seed from the official Arch releng profile.
cp -r /archiso/configs/releng/* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# Keep the hardware catalog inside the live root as well as at build time.
# The installer uses this same file to configure the installed bootloader, so
# product matching, DTB staging, and post-install kernel updates cannot drift.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  install -Dm644 /configs/aarch64/platforms.json \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/aarch64-platforms.json"
fi

# releng only ships packages.x86_64. Derive the aarch64 list from it and drop the
# entries that are x86-only, or that Arch Linux ARM does not carry at all, so the
# first pacman resolve does not fail on packages that cannot exist for ARM.
#
# Arch Linux ARM has no package named plain "linux"; its generic ARMv8 kernel is
# linux-aarch64. Leaving releng's "linux" in place fails the first resolve, so it
# is remapped rather than dropped -- unlike x86_64, aarch64 has no second kernel
# to fall back on, so this list's kernel is the one the live ISO boots.
pkg_list="$build_cache_dir/packages.${OMARCHY_ARCH}"
if [[ $OMARCHY_ARCH == "aarch64" && ! -f $pkg_list ]]; then
  sed -E 's/^linux$/linux-aarch64/' "$build_cache_dir/packages.x86_64" |
    grep -Fxv -f <(grep -hv '^#\|^$' /builder/aarch64-excludes.packages) >"$pkg_list"
  rm -f "$build_cache_dir/packages.x86_64"
fi

# We rely on the global CDN; drop reflector.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our archiso profile additions.
cp -r /configs/* "$build_cache_dir/"

# uefi.grub installs every entry in efiboot/loader/entries, so the entry for the
# other architecture would show up in the boot menu pointing at a kernel this ISO
# does not carry. Keep only this build's entry and aim loader.conf at it.
_boot_entries="$build_cache_dir/efiboot/loader/entries"
find "$_boot_entries" -name '01-archiso-*-linux.conf' \
  ! -name "01-archiso-${OMARCHY_ARCH}-linux.conf" -delete
sed -i "s|^default .*|default 01-archiso-${OMARCHY_ARCH}-linux.conf|" \
  "$build_cache_dir/efiboot/loader/loader.conf"

# BIOS is x86-only, so the syslinux tree is dead weight on aarch64 (profiledef
# drops bios.syslinux from bootmodes there).
#
# The GRUB configs template their paths through %ARCH%, but name the kernel
# outright: aarch64 boots linux-aarch64, not the T2 kernel. The grub_cpu guards
# elsewhere in those files are evaluated by GRUB at boot and never match on ARM,
# so they need no edit. xe.enable_panel_replay is an Intel Xe knob with nothing
# to act on here.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  rm -rf "$build_cache_dir/syslinux"
  # linux-aarch64's stock preset writes /boot/initramfs-linux.img, so the boot
  # configs name that rather than a per-kernel variant.
  sed -i -e 's/vmlinuz-linux-t2/vmlinuz-linux-aarch64/g' \
    -e 's/initramfs-linux-t2\.img/initramfs-linux.img/g' \
    -e 's/ xe\.enable_panel_replay=0//g' \
    "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"

  # Presets are keyed by pkgbase. linux-t2 does not exist on ARM, and releng's
  # linux.preset is keyed to a pkgbase nothing here provides, so both are dead
  # weight. linux-aarch64 ships its own preset and owns that path, so the
  # profile cannot supply a replacement without a pacstrap file conflict.
  #
  # That stock preset builds against /etc/mkinitcpio.conf -- it does NOT pick up
  # mkinitcpio.conf.d/archiso.conf, because a preset's config is passed as -c and
  # -c ignores drop-ins. Since omarchy-settings replaces /etc/mkinitcpio.conf
  # with the target system's hooks, the initramfs pacstrap produces has no
  # archiso hook at all. customize_airootfs.sh below rebuilds it explicitly.
  rm -f "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset" \
    "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset"

  # Drop the two x86-only hooks from the live initramfs.
  #
  # microcode has no CPU microcode to bundle on ARM. memdisk exists to boot an
  # ISO that syslinux MEMDISK loaded into RAM -- a BIOS mechanism with no UEFI
  # equivalent -- and it needs memdiskfind from syslinux, which is excluded here
  # as an x86 bootloader. Left in place it fails the initramfs build outright:
  # "binary not found: 'memdiskfind'" and "module not found: 'phram'".
  sed -i -e 's/ microcode / /' -e 's/ memdisk / /' \
    "$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/archiso.conf"

  # archiso globs ${pacstrap_dir}/boot/vmlinuz-* for both the ISO 9660 tree and
  # the FAT EFI image, but Arch Linux ARM installs its kernel as /boot/Image --
  # the ARM64 convention -- so those globs match nothing and the build dies with
  # no kernel to copy. Bridge the naming in the chroot, after pacstrap has put
  # the kernel there and before the boot stages look for it.
  #
  # customize_airootfs.sh is deprecated upstream but is the only post-pacstrap
  # in-chroot hook archiso offers. A pacman hook in the target root would be the
  # non-deprecated alternative if this stops being supported.
  cat >"$build_cache_dir/airootfs/root/customize_airootfs.sh" <<'CUSTOMIZE'
#!/bin/bash
set -e

# The package-owned preset carries the authoritative kernel version for the
# kernel that was just installed. Read it before anything else touches /boot,
# and leave the file alone -- replacing it would destroy the one reliable
# source of this value.
# shellcheck source=/dev/null
source /etc/mkinitcpio.d/linux-aarch64.preset
kver=${ALL_kver:?linux-aarch64 preset defines no ALL_kver}
[[ -d /usr/lib/modules/$kver ]] ||
  { echo "ERROR: no modules for linux-aarch64 kernel $kver" >&2; exit 1; }

# Unconditionally, so a reused root cannot keep an alias for an older kernel.
cp -a /boot/Image /boot/vmlinuz-linux-aarch64

# Regenerate the live initramfs against archiso's config.
#
# The stock preset builds against /etc/mkinitcpio.conf, which omarchy-settings
# replaces with the TARGET system's hooks (encrypt, fsck, btrfs-overlayfs and
# friends). The resulting image has no archiso hook, so it cannot find or mount
# the squashfs, and the ISO panics instead of booting.
#
# -c is what releng's preset does too: mkinitcpio translates archiso_config=
# straight into -c, and -c ignores drop-ins rather than layering over the main
# config. A HOOKS-only config is the point here -- MODULES/BINARIES/FILES come
# out empty and compression falls back to mkinitcpio's default, none of which we
# want inherited from the target system's config anyway.
mkinitcpio -c /etc/mkinitcpio.conf.d/archiso.conf -k "$kver" -g /boot/initramfs-linux.img

# Fail loudly rather than shipping an ISO that builds and then panics. mkarchiso
# runs this script under set -e, so a failure here fails the build -- which a
# post-transaction pacman hook could not do, since AbortOnFail applies only to
# pre-transaction hooks.
initramfs_hooks=$(lsinitcpio /boot/initramfs-linux.img | grep -oE 'hooks/[a-z_0-9-]+$' | sed 's|hooks/||' | sort -u)
for required in archiso archiso_loop_mnt; do
  printf '%s\n' "$initramfs_hooks" | grep -qx "$required" || {
    echo "ERROR: live initramfs has no '$required' hook; it would not boot" >&2
    echo "       hooks present: $(printf '%s' "$initramfs_hooks" | tr '\n' ' ')" >&2
    exit 1
  }
done

# A mismatch here means the initramfs was built for a kernel other than the one
# /boot/vmlinuz-linux-aarch64 now is.
lsinitcpio -a /boot/initramfs-linux.img | grep -q "Kernel: $kver" || {
  echo "ERROR: initramfs kernel does not match installed $kver" >&2
  exit 1
}
CUSTOMIZE
  chmod +x "$build_cache_dir/airootfs/root/customize_airootfs.sh"
fi

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
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  NODE_TARBALL_SUFFIX="linux-arm64.tar.gz"
else
  NODE_TARBALL_SUFFIX="linux-x64.tar.gz"
fi
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "$NODE_TARBALL_SUFFIX" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "$NODE_TARBALL_SUFFIX" | awk '{print $1}')
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
arch_packages=(git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)

# linux-t2 is the Apple T2 kernel and exists only for x86_64. aarch64 boots the
# linux-aarch64 remapped into the list from releng above, so no kernel is added
# here for ARM.
if [[ $OMARCHY_ARCH != "aarch64" ]]; then
  arch_packages=(linux-t2 "${arch_packages[@]}")
else
  # Snapdragon laptops (Lenovo ThinkPad X13s and friends) need Qualcomm firmware
  # loaded before the display controller, GPU, and USB/PCIe links come up. Without
  # it the kernel boots to a black panel with no console, which is the failure we
  # are chasing on real hardware -- QEMU never needed it because virtio needs no
  # blobs. releng's list carries only linux-firmware, which no longer bundles the
  # qcom blobs since upstream split them out.
  arch_packages+=(linux-firmware-qcom)
fi
printf '%s\n' "${arch_packages[@]}" >> "$pkg_list"

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
#
# x86_64 only: on aarch64 there is no second kernel to drop -- linux-aarch64 is
# the one the ISO boots -- and broadcom-wl was already pruned when the list was
# derived from releng above.
if [[ $OMARCHY_ARCH != "aarch64" ]]; then
  sed -i -E '/^(linux|broadcom-wl)$/d' "$pkg_list"
fi

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
  pacman --config "$pacman_online_conf" --noconfirm -Syw "$OMARCHY_RUNTIME_PACKAGE" --cachedir "$bootstrap_cache_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
  # Package compression follows the distribution: Arch ships zstd, Arch Linux ARM
  # xz. Accept either rather than assuming the archive this repo was written on.
  omarchy_pkg=$(find "$bootstrap_cache_dir" -maxdepth 1 -type f \
    \( -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.zst" -o -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.xz" \) | sort | head -1)
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

# These shipped copies are what the installer pacstraps from at install time, so
# they must exclude the same packages the offline mirror does. Filtering only the
# mirror would produce an ISO that builds cleanly and then fails during install
# on the first x86-only package the list still names.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  for shipped in omarchy-base.packages omarchy-other.packages; do
    shipped_path="$build_cache_dir/airootfs/usr/share/omarchy-iso/$shipped"
    grep -Fxv -f <(grep -hv '^#\|^$' /builder/aarch64-excludes.packages) \
      "$shipped_path" >"$shipped_path.filtered" || true
    mv "$shipped_path.filtered" "$shipped_path"
  done
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
    cat "$pkg_list"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}"
    # Microcode is handled by aarch64-excludes.packages, applied below.
    grep -hv '^#\|^$' /builder/archinstall.packages
    # Always include the selected Omarchy packages so the target install can
    # find the runtime and companion packages in the offline mirror.
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
    # Platform packages are downloaded into the offline mirror but are not
    # installed in the live root. The installer selects only the packages for
    # the machine whose SMBIOS record matched the AArch64 platform manifest.
    if [[ $OMARCHY_ARCH == "aarch64" ]]; then
      # Installed during the early bootstrap so the target trusts ALARM package
      # signatures before its first network-backed pacman transaction.
      printf '%s\n' archlinuxarm-keyring
      jq -r '.platforms[].packages[]?' /configs/aarch64/platforms.json
    fi
  } | sort -u
)

# Omarchy's package lists are written for x86_64 and name hardware support that
# cannot exist on ARM (Apple T2, Intel graphics, NVIDIA, x86 laptop drivers) plus
# a few things Arch Linux ARM does not carry. pacman aborts the entire -Syw on
# the first unresolvable target, so these are dropped before the mirror is built.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  before=${#all_packages[@]}
  mapfile -t all_packages < <(
    printf '%s\n' "${all_packages[@]}" |
      grep -Fxv -f <(grep -hv '^#\|^$' /builder/aarch64-excludes.packages)
  )
  echo "aarch64: excluded $((before - ${#all_packages[@]})) x86-only packages from the offline mirror"
fi

# With --local-source we already built these omarchy* packages directly into
# the mirror; strip them from the pacman -Syw list so it doesn't try to fetch
# the published versions on top.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  # OMARCHY_EXTRA_PKGBUILDS were built locally too, so they must be stripped as
  # well -- they are precisely the packages with no published build for this
  # architecture, and leaving them in makes pacman abort the whole -Syw.
  read -ra _extra_built <<<"${OMARCHY_EXTRA_PKGBUILDS:-}"
  mapfile -t all_packages < <(
    printf '%s\n' "${all_packages[@]}" |
      grep -Fxv \
        -e "$OMARCHY_RUNTIME_PACKAGE" \
        -e "$OMARCHY_SETTINGS_PACKAGE" \
        -e "$OMARCHY_NVIM_PACKAGE" \
        "${_extra_built[@]/#/-e}" || true
  )
fi

mkdir -p /tmp/offlinedb
download_offline_packages() {
  pacman --config "$pacman_online_conf" --noconfirm -Syw \
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
  pacman --config "$pacman_online_conf" --noconfirm \
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
  # OMARCHY_EXTRA_PKGBUILDS were built into the mirror alongside the Omarchy
  # packages and are equally absent from the -Syw resolution, so they need the
  # same treatment or the prune below deletes them again.
  read -ra _extra_local <<<"${OMARCHY_EXTRA_PKGBUILDS:-}"
  for local_package_name in \
    "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE" \
    "${_extra_local[@]}"; do
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
rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
# Index whichever compression this distribution's packages use -- zstd on Arch,
# xz on Arch Linux ARM. A glob for one alone silently indexes nothing on the
# other, producing an ISO that boots and then installs no packages.
shopt -s nullglob
offline_pkgs=("$offline_mirror_dir"/*.pkg.tar.zst "$offline_mirror_dir"/*.pkg.tar.xz)
shopt -u nullglob
if (( ${#offline_pkgs[@]} == 0 )); then
  echo "ERROR: no packages found in $offline_mirror_dir to index" >&2
  exit 1
fi
repo-add "$offline_mirror_dir/offline.db.tar.gz" "${offline_pkgs[@]}"

# aarch64 boot: stage Snapdragon X device trees where GRUB can read them.
#
# Qualcomm's UEFI publishes ACPI only, and Linux has no ACPI support for
# x1e80100 -- it needs a flattened device tree or it dies before any console
# exists, which is the silent black screen a Yoga Slim 7x shows. GRUB's
# `devicetree` command installs one into the EFI configuration table, so the
# blob has to be reachable from the boot medium *before* the kernel is loaded.
#
# The DTBs are already on the ISO: linux-aarch64 ships /boot/dtbs/ and the live
# root carries all 1507 of them. But they are inside the squashfs, which nothing
# can read at GRUB time, so a second copy is staged outside it.
#
# It goes into the profile's grub/ directory rather than the ESP on purpose.
# mkarchiso's _make_bootmode_uefi.grub copies every non-*.cfg entry of
# ${profile}/grub/ straight into ISO 9660 at /boot/grub/ with cp -r (see
# archiso/archiso/mkarchiso, "Copy GRUB files"; shopt -s extglob is set at the
# top of that script), so this needs no mkarchiso patch. And the FAT ESP is
# sized for BOOTAA64.EFI alone -- _make_boot_on_fat is not even called on the
# grub path, so the kernel, initramfs and these blobs all live on ISO 9660.
#
# The source is the package file the live root is actually pacstrapped from
# (pacman-offline.conf's only repo is this mirror, and it has just been pruned
# to the resolved set), so the staged DTB can never be a different kernel
# version from the one that boots it.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  # This is the canonical list of machines whose UEFI does not provide Linux
  # with a usable hardware description. Do not stage all kernel DTBs: normal
  # ARM firmware already supplies one, and loading the wrong board's DTB is
  # unsafe. The manifest will also drive live and installed boot selection.
  platform_manifest=/configs/aarch64/platforms.json
  mapfile -t platform_dtbs < <(
    jq -er '.platforms[] | select(.boot.hardware_description == "dtb-override") | .boot.dtb' \
      "$platform_manifest" | sort -u
  )
  (( ${#platform_dtbs[@]} > 0 )) || {
    echo "ERROR: no AArch64 platform DTBs in $platform_manifest" >&2
    exit 1
  }

  # Anchored on a digit: "linux-aarch64-" also prefixes linux-aarch64-headers.
  kernel_pkg_file=$(printf '%s\n' "${offline_pkgs[@]}" |
    grep -E '/linux-aarch64-[0-9]' | head -1)
  if [[ -z $kernel_pkg_file ]]; then
    echo "ERROR: no linux-aarch64 package in the offline mirror to take DTBs from" >&2
    exit 1
  fi

  dtb_stage_dir="$build_cache_dir/grub/dtbs"
  mkdir -p "$dtb_stage_dir"
  bsdtar -xf "$kernel_pkg_file" -C "$dtb_stage_dir" \
    --strip-components=2 "${platform_dtbs[@]/#/boot/dtbs/}"

  # Fail the build rather than ship an ISO whose Snapdragon entry silently does
  # not exist: the grub.cfg guard is an -f test, so a missing blob is invisible
  # at boot -- the menu entry just is not there.
  for _dtb in "${platform_dtbs[@]}"; do
    [[ -s "$dtb_stage_dir/$_dtb" ]] ||
      { echo "ERROR: $_dtb missing from $(basename "$kernel_pkg_file")" >&2; exit 1; }
  done
  echo "aarch64: staged ${#platform_dtbs[@]} platform device tree(s) from $(basename "$kernel_pkg_file")"
fi

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
      grep -hv '^#\|^$' /builder/archinstall.packages
      # Read the shipped copy, which is what _runtime_package_list reads at
      # install time, not the build-time source it came from.
      grep -hv '^#\|^$' \
        "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
      printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" \
        "$OMARCHY_NVIM_PACKAGE"
      [[ $OMARCHY_ARCH == "aarch64" ]] && printf '%s\n' archlinuxarm-keyring
    } | sort -u | {
      # The shipped omarchy-base.packages is already filtered, but
      # archinstall.packages is read raw here and still names both microcode
      # packages. Apply the same exclusions so this resolves against exactly
      # what the mirror holds.
      if [[ $OMARCHY_ARCH == "aarch64" ]]; then
        grep -Fxv -f <(grep -hv '^#\|^$' /builder/aarch64-excludes.packages)
      else
        cat
      fi
    }
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

# Preserve the network configuration that the installed aarch64 system should
# use after every offline install/finalization step is complete. The build can
# download from a file:// cache, so that override is not automatically suitable
# for the installed machine; OMARCHY_TARGET_PKGS_MIRROR separates the two. For
# normal network builds, reuse OMARCHY_PKGS_MIRROR. Otherwise fall back to the
# channel's tracked public Omarchy URL.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  target_pkgs_mirror="${OMARCHY_TARGET_PKGS_MIRROR:-${OMARCHY_PKGS_MIRROR:-}}"
  if [[ $target_pkgs_mirror != http://* && $target_pkgs_mirror != https://* ]]; then
    target_pkgs_mirror=$(awk '
      /^\[omarchy\]$/ { in_omarchy=1; next }
      /^\[/ { in_omarchy=0 }
      in_omarchy && /^Server = / { sub(/^Server = /, ""); print; exit }
    ' "/configs/aarch64/pacman-online-${OMARCHY_MIRROR}.conf")
  fi
  [[ $target_pkgs_mirror == http://* || $target_pkgs_mirror == https://* ]] ||
    { echo "ERROR: no HTTP(S) Omarchy repository configured for the installed aarch64 system" >&2; exit 1; }

  install -Dm644 /configs/aarch64/pacman-target.conf \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/pacman-target.conf"
  sed -i "s|@@OMARCHY_PKGS_MIRROR@@|$target_pkgs_mirror|" \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/pacman-target.conf"
  install -Dm644 /configs/aarch64/mirrorlist-target \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/mirrorlist-target"
fi

# Live ISO uses the offline pacman.conf throughout installation.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO.
# On aarch64 there is no archiso package, so run the pinned submodule's copy.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  # /archiso is mounted read-only and is a pinned upstream checkout, so patch a
  # working copy instead of the source.
  #
  # archiso's grub-mkstandalone module list is x86-derived. arm64-efi ships no
  # PS/2 keyboard or USB-serial modules, and grub-mkstandalone aborts on the
  # first module it cannot open rather than skipping it. EFI firmware provides
  # console input on ARM, so dropping them costs nothing. Everything else in the
  # list exists for arm64-efi.
  install -m755 /archiso/archiso/mkarchiso "$build_cache_dir/mkarchiso"
  sed -i -E '/grubmodules=\(/,/zstd\)/ s/\b(at_keyboard|keylayouts|usb|usbserial_common|usbserial_ftdi|usbserial_pl2303|usbserial_usbdebug)\b ?//g' \
    "$build_cache_dir/mkarchiso"

  # Force a FAT32 ESP.
  #
  # archiso sizes the EFI image from its contents plus 8 MiB of slack, then only
  # asks for FAT32 at >= 36 MiB. On aarch64 the ESP holds BOOTAA64.EFI and
  # nothing else (_make_boot_on_fat is not called on the grub path -- the kernel
  # and initramfs are read off ISO 9660), so it lands at 16 MiB and mkfs.fat
  # picks FAT16.
  #
  # The UEFI spec only mandates FAT32 for the ESP on non-removable media, so
  # that is legal -- but several ARM64 firmwares, Qualcomm's among the
  # more-reported, simply do not enumerate a FAT16 ESP on removable media. The
  # stick then never appears as a boot option at all, which looks identical to a
  # corrupt image.
  #
  # Raising the floor to 40 MiB trips archiso's own existing FAT32 branch rather
  # than duplicating its logic, and costs ~24 MiB of ISO.
  sed -i -E 's/^(    )if \(\( imgsize_kib >= 36864 \)\); then$/\1(( imgsize_kib < 40960 )) \&\& imgsize_kib=40960\n\1if (( imgsize_kib >= 36864 )); then/' \
    "$build_cache_dir/mkarchiso"
  mkarchiso_bin="$build_cache_dir/mkarchiso"
else
  mkarchiso_bin=mkarchiso
fi
"$mkarchiso_bin" -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
