#!/bin/bash
# Build Omarchy packages from mounted source (/omarchy-source + /omarchy-pkgs)
# and place the resulting .pkg.tar.zst files in the offline mirror.

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

# Local-source packages must replace every cached build of the same package,
# even when the checkout's generated pkgver sorts below a published build.
# Otherwise the later generic cache pruning can silently keep edge instead.
for pkg in "${packages[@]}"; do
  rm -f "$offline_mirror_dir/$pkg-"*.pkg.tar.*
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

  su builder -c "
    cd '$pkg_work' &&
    PKGDEST='$work_dir' \
    OMARCHY_SRC=/omarchy-source \
    makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
  "
done

mkdir -p "$offline_mirror_dir"
for package_file in "$work_dir"/*.pkg.tar.zst "$work_dir"/*.pkg.tar.xz; do
  [[ -e $package_file ]] || continue
  destination="$offline_mirror_dir/$(basename "$package_file")"

  # A cached signature belongs to the previously downloaded or locally built
  # package. Keeping it beside a newly built package makes pacman reject the
  # otherwise valid local-source build.
  rm -f "$destination" "$destination.sig"
  mv "$package_file" "$destination"
done

echo
echo "Built Omarchy packages, placed in $offline_mirror_dir:"
ls "$offline_mirror_dir"/omarchy*.pkg.tar.{zst,xz} 2>/dev/null | sed 's|^|  |'
