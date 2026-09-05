#!/bin/bash
# Build Omarchy packages from mounted source (/omarchy-source + /omarchy-pkgs)
# and place the resulting package files in the offline mirror.

set -e

offline_mirror_dir="$1"
if [[ -z $offline_mirror_dir ]]; then
  echo "Usage: build-omarchy-packages.sh <offline-mirror-dir>" >&2
  exit 1
fi

if [[ ! -d /omarchy-source ]]; then
  echo "ERROR: /omarchy-source not mounted (pass --local-source or set OMARCHY_SOURCE_PATH)" >&2
  exit 1
fi
if [[ ! -d /omarchy-pkgs ]]; then
  echo "ERROR: /omarchy-pkgs not mounted (set OMARCHY_PKGS_PATH or place ../omarchy-pkgs)" >&2
  exit 1
fi

work_dir=/tmp/omarchy-pkg-build
rm -rf "$work_dir"
mkdir -p "$work_dir"

if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-omarchy-pkg-builder
chmod 440 /etc/sudoers.d/99-omarchy-pkg-builder
chown builder:builder "$work_dir"

pacman -Sy --noconfirm

: "${OMARCHY_RUNTIME_PACKAGE:=omarchy-dev}"
: "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings-dev}"
: "${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}"

packages=(
  "$OMARCHY_SETTINGS_PACKAGE"
  "$OMARCHY_RUNTIME_PACKAGE"
  "$OMARCHY_NVIM_PACKAGE"
)

# Space-separated extra pkgbuilds from omarchy-pkgs to build alongside the
# Omarchy packages. Needed when a package the install lists require has no build
# published for this architecture yet -- on aarch64 that is tzupdate, tensaku,
# and hyprland-preview-share-picker, which the live ISO and target install both
# expect. The live ISO pacstraps from the offline mirror (profiledef.sh sets
# pacman_conf=pacman-offline.conf), so building them here is enough; they do not
# need publishing to a repo first.
if [[ -n ${OMARCHY_EXTRA_PKGBUILDS:-} ]]; then
  read -ra _extra <<<"$OMARCHY_EXTRA_PKGBUILDS"
  packages+=("${_extra[@]}")
  echo "Also building: ${_extra[*]}"
fi

# Local-source packages must replace every cached build of the same package,
# even when the checkout's generated pkgver sorts below a published build.
# Otherwise the later generic cache pruning can silently keep edge instead.
for pkg in "${packages[@]}"; do
  rm -f "$offline_mirror_dir/$pkg-"*.pkg.tar.*

  # The host's pacman cache is bind-mounted in and shared across builds. A local
  # rebuild produces the same filename with different content, and pacman
  # prefers a cached file over the mirror copy -- so a stale entry fails
  # checksum validation during pacstrap. Drop only what we are rebuilding,
  # rather than the whole host cache.
  rm -f "/var/cache/pacman/pkg/$pkg-"*.pkg.tar.*
done

for pkg in "${packages[@]}"; do
  echo "----------------------------------------"
  echo "Building $pkg"
  echo "----------------------------------------"
  pkg_work="$work_dir/$pkg"
  if [[ ! -d "/omarchy-pkgs/pkgbuilds/$pkg" ]]; then
    echo "ERROR: package source not found: /omarchy-pkgs/pkgbuilds/$pkg" >&2
    exit 1
  fi
  cp -a "/omarchy-pkgs/pkgbuilds/$pkg" "$pkg_work"
  chown -R builder:builder "$pkg_work"

  # Omarchy's pkgbuilds declare arch=('x86_64') because that is all upstream
  # targets, but they build from source and carry nothing x86-specific, so
  # makepkg's architecture check is the only thing stopping them on ARM. None
  # declare arch=('any'), so the output is still tagged aarch64 correctly.
  # The cleaner fix is adding aarch64 to those arch=() arrays in omarchy-pkgs.
  makepkg_args=(--noconfirm --skippgpcheck --skipchecksums -f)
  [[ ${OMARCHY_ARCH:-x86_64} == "aarch64" ]] && makepkg_args+=(--ignorearch)

  # The Omarchy packages depend on each other and on packages this build has not
  # published yet, so they are built --nodeps deliberately. The extras are
  # ordinary third-party software whose dependencies all resolve from the
  # distribution repos -- gtk4, libadwaita and the Rust toolchain among them --
  # so let makepkg install them. builder has passwordless sudo for pacman above,
  # which is what --syncdeps needs.
  if [[ " ${_extra[*]:-} " == *" $pkg "* ]]; then
    makepkg_args+=(--syncdeps)
  else
    makepkg_args+=(--nodeps)
  fi

  su builder -c "
    cd '$pkg_work' &&
    PKGDEST='$work_dir' \
    OMARCHY_SRC=/omarchy-source \
    makepkg ${makepkg_args[*]}
  "
done

mkdir -p "$offline_mirror_dir"

# makepkg's PKGEXT is distribution-set: Arch defaults to .pkg.tar.zst, Arch Linux
# ARM to .pkg.tar.xz. Match whatever this container produced rather than assuming.
shopt -s nullglob
for package_file in "$work_dir"/*.pkg.tar.zst "$work_dir"/*.pkg.tar.xz; do
  destination="$offline_mirror_dir/$(basename "$package_file")"

  # A cached signature belongs to the previously downloaded or locally built
  # package. Keeping it beside a newly built package makes pacman reject the
  # otherwise valid local-source build.
  rm -f "$destination" "$destination.sig"
  mv "$package_file" "$destination"
done

echo
echo "Built Omarchy packages, placed in $offline_mirror_dir:"
ls "$offline_mirror_dir"/omarchy*.pkg.tar.zst "$offline_mirror_dir"/omarchy*.pkg.tar.xz 2>/dev/null | sed 's|^|  |'
