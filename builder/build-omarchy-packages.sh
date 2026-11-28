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
  echo "ERROR: /omarchy-source not mounted (pass --local-source)" >&2
  exit 1
fi
if [[ ! -d /omarchy-pkgs ]]; then
  echo "ERROR: /omarchy-pkgs not mounted (pass --local-source)" >&2
  exit 1
fi

work_dir=/tmp/omarchy-pkg-build
rm -rf "$work_dir"
mkdir -p "$work_dir"

if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
# Parallel compression for the package archives; the defaults are single-threaded.
cat > /home/builder/.makepkg.conf <<'CONF'
COMPRESSXZ=(xz -c -z -T0 -)
COMPRESSZST=(zstd -c -z -q -T0 -)
CONF
chown builder:builder /home/builder/.makepkg.conf
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-omarchy-pkg-builder
chmod 440 /etc/sudoers.d/99-omarchy-pkg-builder
chown builder:builder "$work_dir"

pacman -Sy --noconfirm

: "${OMARCHY_RUNTIME_PACKAGE:=omarchy-dev}"
: "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings-dev}"
: "${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}"

# build-iso.sh names them in OMARCHY_LOCAL_PACKAGES; all three by default.
read -ra packages <<<"${OMARCHY_LOCAL_PACKAGES:-$OMARCHY_SETTINGS_PACKAGE $OMARCHY_RUNTIME_PACKAGE $OMARCHY_NVIM_PACKAGE}"

# Local-source packages must replace every cached build of the same package,
# even when the checkout's generated pkgver sorts below a published build.
# Otherwise the later generic cache pruning can silently keep edge instead.
for pkg in "${packages[@]}"; do
  rm -f "$offline_mirror_dir/$pkg-"*.pkg.tar.*
done

# Copy $1's recipe from the pkgs checkout to $work_dir/$1, owned by builder.
stage_recipe() {
  echo "----------------------------------------"
  echo "Building $1"
  echo "----------------------------------------"
  if [[ ! -d "/omarchy-pkgs/pkgbuilds/$1" ]]; then
    echo "ERROR: package source not found: /omarchy-pkgs/pkgbuilds/$1" >&2
    exit 1
  fi
  cp -a "/omarchy-pkgs/pkgbuilds/$1" "$work_dir/$1"
  chown -R builder:builder "$work_dir/$1"
}

for pkg in "${packages[@]}"; do
  stage_recipe "$pkg"
  pkg_work="$work_dir/$pkg"

  # The container's makepkg.conf compresses single-threaded and makes with one
  # job; use every core of the build host for both. su resets the environment,
  # so the source path is passed explicitly.
  su builder -c "
    cd '$pkg_work' &&
    PKGDEST='$work_dir' \
    OMARCHY_SRC=/omarchy-source \
    MAKEFLAGS='-j$(nproc)' \
    makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
  "
done

# Further packages from the pkgs checkout (OMARCHY_EXTRA_LOCAL_PACKAGES), built
# in place of their published builds: a patched dependency under test, say.
# Unlike the Omarchy packages they compile, so what they build with is
# installed first, by root here rather than by makepkg through sudo. Each is
# installed once built, so one later in the list builds against it: name a
# dependency before what depends on it. build-iso.sh keeps the published build
# of each out of the mirror.
read -r -a extra_packages <<<"${OMARCHY_EXTRA_LOCAL_PACKAGES:-}"
for pkg in "${extra_packages[@]}"; do
  rm -f "$offline_mirror_dir/$pkg-"[0-9]*.pkg.tar.*
  stage_recipe "$pkg"
  pkg_work="$work_dir/$pkg"
  mapfile -t build_deps < <(
    su builder -c "cd '$pkg_work' && makepkg --printsrcinfo" |
      sed -n "s/^\t\(make\|check\)\?depends\(_$(uname -m)\)\? = //p"
  )
  # Only what nothing installed satisfies, as makepkg -s asks (pacman -T):
  # pacman -S would fail on a version only an extra built before has, or
  # downgrade that extra to the published build.
  mapfile -t build_deps < <(pacman -T "${build_deps[@]}")
  if (( ${#build_deps[@]} > 0 )); then
    pacman -S --needed --noconfirm --asdeps "${build_deps[@]}"
  fi
  # makepkg checks signed sources against the keys the recipe ships, as
  # omarchy-pkgs' own build does.
  su builder -c "
    cd '$pkg_work' &&
    if [[ -d keys/pgp ]]; then gpg --batch --import keys/pgp/*.asc; fi &&
    PKGDEST='$work_dir' \
    MAKEFLAGS='-j$(nproc)' \
    makepkg --noconfirm --nodeps -f
  "
  pacman -U --noconfirm "$work_dir/$pkg-"[0-9]*.pkg.tar.*
done

mkdir -p "$offline_mirror_dir"
# Arch Linux ARM's makepkg.conf still produces .pkg.tar.xz, so match every
# archive extension rather than assuming zstd.
shopt -s nullglob
package_files=("$work_dir"/*.pkg.tar.*)
shopt -u nullglob
if (( ${#package_files[@]} == 0 )); then
  echo "ERROR: makepkg produced no package archives in $work_dir" >&2
  exit 1
fi
for package_file in "${package_files[@]}"; do
  [[ $package_file == *.sig ]] && continue
  destination="$offline_mirror_dir/$(basename "$package_file")"

  # A cached signature belongs to the previously downloaded or locally built
  # package. Keeping it beside a newly built package makes pacman reject the
  # otherwise valid local-source build.
  rm -f "$destination" "$destination.sig"
  mv "$package_file" "$destination"
done

echo
echo "Built Omarchy packages, placed in $offline_mirror_dir:"
# shellcheck disable=SC2010 # package file names, which makepkg makes
ls "$offline_mirror_dir"/omarchy*.pkg.tar.* | grep -v '\.sig$' | sed 's|^|  |'
for pkg in "${extra_packages[@]}"; do
  printf '  %s\n' "$offline_mirror_dir/$pkg-"[0-9]*.pkg.tar.*
done
