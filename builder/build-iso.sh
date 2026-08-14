#!/bin/bash

set -e

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"
# 1 (default): bake the target system into a prebuilt rootfs squashfs and ship
# a mirror pruned to the hardware-conditional closure. 0: legacy-equivalent ISO
# (full mirror, no image) for A/B comparison and same-day escape.
OMARCHY_ROOTFS_IMAGE="${OMARCHY_ROOTFS_IMAGE:-1}"

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
pacman --noconfirm -Sy archlinux-keyring
# Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
# so this container can be months behind the mirror it installs from. A plain
# -Sy install is then a partial upgrade — new packages linked against a glibc
# the container doesn't have yet.
pacman --noconfirm -Syu archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli

# Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
# during the build without keyserver lookups).
pacman-key --add /builder/omarchy.gpg
pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

# omarchy-keyring is needed inside the offline mirror too.
pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Sy omarchy-keyring
pacman-key --populate omarchy

# Append the [omarchy] repo to the container's /etc/pacman.conf so subsequent
# tools (notably makepkg in build-omarchy-packages.sh) can resolve omarchy-
# only build deps like limine-snapper-sync and limine-mkinitcpio-hook.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
  awk '/^\[omarchy\]/,/^$/' /configs/pacman-online-${OMARCHY_MIRROR}.conf >> /etc/pacman.conf
fi

# Build locations. $build_cache_dir is the mkarchiso profile dir. Package
# downloads land in $download_cache_dir (host-mounted by omarchy-iso-make at a
# neutral path), NOT inside the profile's airootfs: the shipped mirror is
# pruned to the hardware-conditional closure before mkarchiso runs, and pruning
# a mount of the host cache would prune the host cache.
build_cache_dir=/var/cache
download_cache_dir=/var/cache/omarchy-build
offline_mirror_dir="$download_cache_dir/mirror/offline"
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
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
arch_packages=(linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >> "$build_cache_dir/packages.x86_64"

# The installer restores the prebuilt rootfs image with unsquashfs. releng has
# shipped squashfs-tools for years, but the archiso submodule isn't checked out
# on the host, so assert rather than assume: a live environment without
# unsquashfs could only pacstrap. Appended before the offline-mirror package
# collection below so the live pacstrap can actually resolve it.
grep -qx 'squashfs-tools' "$build_cache_dir/packages.x86_64" ||
  echo 'squashfs-tools' >> "$build_cache_dir/packages.x86_64"

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
sed -i -E '/^(linux|broadcom-wl)$/d' "$build_cache_dir/packages.x86_64"

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
  pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw "$OMARCHY_RUNTIME_PACKAGE" --cachedir "$bootstrap_cache_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
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

# Collect every package we want available in the offline mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    cat "$build_cache_dir/packages.x86_64"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}"
    grep -hv '^#\|^$' /builder/archinstall.packages
    # Always include the selected Omarchy packages so the target install can
    # find the runtime and companion packages in the offline mirror.
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u
)

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
  pacman --config /configs/pacman-online-${OMARCHY_MIRROR}.conf --noconfirm -Syw \
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
  pacman --config "/configs/pacman-online-${OMARCHY_MIRROR}.conf" --noconfirm \
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
rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
repo-add "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# pacman-offline.conf resolves [offline] at /var/cache/omarchy/mirror/offline.
# Everything that runs against it at BUILD time — the rootfs pacstrap, the
# expected-package resolvers, and mkarchiso's live-environment pacstrap — must
# see the FULL mirror in the download cache; symlink rather than duplicate.
# What ships in the ISO's airootfs at that same path is a separate, real
# directory (pruned conditional closure, or a full copy for the legacy build).
mkdir -p /var/cache/omarchy/mirror
ln -sf "$offline_mirror_dir" /var/cache/omarchy/mirror/offline

# Denominator for the install dashboard's progress bar, LEGACY VARIANT ONLY
# (the rootfs-image build counts its local db directly — see
# build_rootfs_image). Resolving the mirror's own package lists against the
# mirror we just indexed, with an empty local db, is the question pacstrap asks
# at install time — same resolver, same repo, same lists — so no hand-kept
# constant can drift.
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

# ─────────────────────────────────────────────────────────────────────────────
# Prebuilt target rootfs image: pacstrap the full target package set NOW, at
# build time, ship it as a zstd squashfs, and let the installer restore it with
# multithreaded unsquashfs instead of replaying ~925 pacman extractions. The
# shipped mirror then only carries the hardware-conditional closure
# (omarchy-other.packages ∪ {linux-t2, tailscale}) that install time can still
# ask for. Everything here runs after repo-add so the full mirror is indexed.
# ─────────────────────────────────────────────────────────────────────────────
build_rootfs_image() {
  local rootfs_dir=/tmp/omarchy-target-rootfs
  local rootfs_sfs_dir="$build_cache_dir/airootfs/var/cache/omarchy/rootfs"
  local rootfs_pacman_conf=/tmp/pacman-rootfs.conf
  local iso_share_dir="$build_cache_dir/airootfs/usr/share/omarchy-iso"
  local -a rootfs_packages deferred_boot_hooks conditional_targets
  local hook resolved_conditionals filename package_count hardlink_conflicts
  local phases_impl
  local copied=0

  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir" "$rootfs_sfs_dir"

  # Target package set: what the legacy install-time flow ends up with, minus
  # the two install-time conditionals. tailscale is in archinstall.packages so
  # the MIRROR carries it, but it is only ever installed when an autoinstall
  # drive stages an auth key — it must never be baked into the image. linux
  # stays baked; the T2 kernel swap happens at install time against the pruned
  # mirror. rootfs-extra.packages covers what archinstall used to add at
  # install time (early bootstrap extras, LuaRocks split, zram-generator,
  # the PipeWire application set).
  mapfile -t rootfs_packages < <(
    {
      grep -hv '^#\|^$' /builder/archinstall.packages | grep -vx 'tailscale'
      grep -hv '^#\|^$' "$iso_share_dir/omarchy-base.packages"
      grep -hv '^#\|^$' /builder/rootfs-extra.packages
      printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" \
        "$OMARCHY_NVIM_PACKAGE"
    } | sort -u
  )

  # Point pacman's CacheDir at the mirror itself so pacstrap -c consumes the
  # package files in place instead of copying ~3GB through the container's
  # /var/cache/pacman/pkg — the same trick _mount_offline_package_cache plays
  # at install time. Nothing is ever downloaded INTO it: every resolved file
  # is already there.
  sed '/^\[options\]/a CacheDir = /var/cache/omarchy/mirror/offline/' \
    "$build_cache_dir/pacman-offline.conf" >"$rootfs_pacman_conf"

  # Mask the same hooks the installer masks around its pacstrap: no initramfs
  # or UKI is built into the image, leaving the identical end state to the
  # legacy masked pacstrap — finalize_limine_boot's limine-update builds the
  # UKI from exactly this state at install time. Masks go in the CONTAINER's
  # /etc/pacman.d/hooks (config-dir hooks override same-named hooks from the
  # target's /usr/share/libalpm/hooks) and MUST come off before mkarchiso: the
  # live environment's initramfs is built by these very hooks during
  # mkarchiso's own pacstrap.
  #
  # The single source of truth is DEFERRED_BOOT_HOOKS in
  # orchestrator/phases_impl.py — extracted, not copied, so a hook added there
  # cannot silently bake a boot artifact into the image that the install-time
  # flow defers. The count guard turns a format change into a build failure
  # instead of an empty mask list.
  phases_impl="$build_cache_dir/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py"
  mapfile -t deferred_boot_hooks < <(
    sed -n '/^DEFERRED_BOOT_HOOKS = (/,/^)/p' "$phases_impl" |
      grep -oE '"[^"]+\.hook"' | tr -d '"'
  )
  if (( ${#deferred_boot_hooks[@]} < 5 )); then
    echo "ERROR: extracted only ${#deferred_boot_hooks[@]} entries of DEFERRED_BOOT_HOOKS" >&2
    echo "       from $phases_impl; expected at least 5. Fix the extraction in" >&2
    echo "       build-iso.sh to match the tuple's current formatting." >&2
    exit 1
  fi
  mkdir -p /etc/pacman.d/hooks
  for hook in "${deferred_boot_hooks[@]}"; do
    ln -sf /dev/null "/etc/pacman.d/hooks/$hook"
  done

  echo "Building target rootfs image (${#rootfs_packages[@]} package targets)..."
  # -G: never copy the container keyring (installs init a per-machine one);
  # -M: target keeps the stock mirrorlist (set_mirrors rewrites it on target).
  pacstrap -C "$rootfs_pacman_conf" -c -G -M "$rootfs_dir" "${rootfs_packages[@]}"

  for hook in "${deferred_boot_hooks[@]}"; do
    rm -f "/etc/pacman.d/hooks/$hook"
  done

  # ── Scrub/normalize: nothing machine-specific may ship in the image. ──

  # Empty machine-id; the installer writes a fresh one per machine with
  # systemd-machine-id-setup right after the restore.
  : >"$rootfs_dir/etc/machine-id"
  if [[ -f "$rootfs_dir/var/lib/dbus/machine-id" && ! -L "$rootfs_dir/var/lib/dbus/machine-id" ]]; then
    rm -f "$rootfs_dir/var/lib/dbus/machine-id"
  fi

  # Never ship a shared pacman keyring key. pacstrap -G already skipped the
  # copy; remove whatever a scriptlet may have seeded anyway.
  rm -rf "$rootfs_dir/etc/pacman.d/gnupg"

  # sshd host keys are generated at first boot by sshdgenkeys, never at
  # pacstrap. If any show up here, something fundamental changed — every
  # install would ship the same private host keys. Stop the build.
  if compgen -G "$rootfs_dir/etc/ssh/ssh_host_*" >/dev/null; then
    echo "ERROR: rootfs image contains SSH host keys; refusing to ship them" >&2
    exit 1
  fi

  # Locale is baked: both configurator JSONs hardcode en_US.UTF-8, and
  # archinstall's minimal_installation wrote locale.gen AND locale.conf — do
  # both for parity. The keymap stays install-time (configure_keyboard).
  sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' "$rootfs_dir/etc/locale.gen"
  arch-chroot "$rootfs_dir" locale-gen
  echo 'LANG=en_US.UTF-8' >"$rootfs_dir/etc/locale.conf"

  # CacheDir pointed at the mirror, so nothing may have landed here: cached
  # packages inside the image would be dead weight in every install.
  if [[ -n $(find "$rootfs_dir/var/cache/pacman/pkg" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    echo "ERROR: rootfs image has a non-empty /var/cache/pacman/pkg" >&2
    exit 1
  fi

  # unsquashfs recreates hardlinks with link(2), and the restore target splits
  # /home, /var/log and /var/cache/pacman/pkg into separate btrfs subvolumes —
  # a hardlink pair crossing one of those boundaries would EXDEV mid-restore.
  # No package is expected to do this; fail loudly if one starts to.
  hardlink_conflicts=$(
    cd "$rootfs_dir" && find . -type f -links +1 -printf '%i\t%p\n' |
      LC_ALL=C sort -n | awk -F'\t' '
        {
          zone = "root"
          if (index($2, "./home/") == 1) zone = "home"
          else if (index($2, "./var/log/") == 1) zone = "log"
          else if (index($2, "./var/cache/pacman/pkg/") == 1) zone = "pkg"
          if ($1 == prev_inode && zone != prev_zone) print $2
          prev_inode = $1; prev_zone = zone
        }'
  )
  if [[ -n $hardlink_conflicts ]]; then
    echo "ERROR: rootfs image has hardlinks crossing subvolume boundaries:" >&2
    printf '%s\n' "$hardlink_conflicts" | sed 's/^/  /' >&2
    exit 1
  fi

  # ── Image + metadata ──

  # The outer airootfs squashfs stores this file uncompressed (see
  # profiledef.sh), so this is the only compression pass it gets.
  mksquashfs "$rootfs_dir" "$rootfs_sfs_dir/omarchy-rootfs.sfs" \
    -comp zstd -Xcompression-level 19 -b 1M -noappend -xattrs

  pacman --root "$rootfs_dir" --dbpath "$rootfs_dir/var/lib/pacman" -Q |
    LC_ALL=C sort >"$iso_share_dir/rootfs-manifest"
  if grep -q '^tailscale ' "$iso_share_dir/rootfs-manifest"; then
    echo "ERROR: tailscale leaked into the rootfs image; it must stay an" >&2
    echo "       install-time conditional (autoinstall auth key only)." >&2
    exit 1
  fi
  if ! grep -q '^linux ' "$iso_share_dir/rootfs-manifest"; then
    echo "ERROR: the rootfs image does not contain the linux kernel" >&2
    exit 1
  fi

  # Denominator for the install dashboard: the restored image IS the installed
  # set, so count its local db entries (one directory per package). Same
  # 600-2000 sanity gate as the legacy resolver: a wrong denominator is worse
  # than none, because it never triggers the dashboard's fallback.
  package_count=$(find "$rootfs_dir/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if (( package_count < 600 || package_count > 2000 )); then
    echo "WARNING: rootfs image package count $package_count is outside the" >&2
    echo "         expected 600-2000 range; shipping no denominator so the install" >&2
    echo "         dashboard falls back to its time-based curve." >&2
  else
    printf '%s\n' "$package_count" >"$iso_share_dir/expected-packages"
    echo "Rootfs image carries $package_count packages."
  fi

  # ── Pruned shipped mirror: only what install time can still ask for. ──
  # Resolve with the resolver that answers the question at install time — the
  # image's own pacman db: the hardware-conditional pool omarchy-apply-system
  # draws from (omarchy-other.packages) plus the two orchestrator-side
  # conditionals, with their not-yet-installed dependency closure.
  #
  # Deliberately NOT --needed: pool members already baked into the image
  # (e.g. sof-firmware, also in archinstall.packages) must KEEP their db
  # entries and files in the shipped repo. After the install-time resync,
  # apply-system may run `pacman -S --needed <member>` — pacman resolves
  # against the sync db before --needed can no-op, so a pruned-out name fails
  # "target not found" even though the package is already installed.
  mapfile -t conditional_targets < <(
    {
      grep -hv '^#\|^$' "$iso_share_dir/omarchy-other.packages"
      printf '%s\n' linux-t2 tailscale
    } | sort -u
  )
  if ! resolved_conditionals="$(
    pacman --config "$build_cache_dir/pacman-offline.conf" \
      --root "$rootfs_dir" --dbpath "$rootfs_dir/var/lib/pacman" \
      --noconfirm -S --print --print-format '%f' \
      "${conditional_targets[@]}"
  )"; then
    echo "ERROR: could not resolve the hardware-conditional package closure" >&2
    echo "       against the rootfs image. omarchy-apply-system would fail to" >&2
    echo "       install from the pruned mirror the same way at install time." >&2
    exit 1
  fi

  while IFS= read -r filename; do
    [[ -n $filename ]] || continue
    if [[ ! -f "$offline_mirror_dir/$filename" ]]; then
      echo "ERROR: resolved conditional package missing from the mirror: $filename" >&2
      exit 1
    fi
    cp "$offline_mirror_dir/$filename" "$shipped_mirror_dir/"
    if [[ -f "$offline_mirror_dir/$filename.sig" ]]; then
      cp "$offline_mirror_dir/$filename.sig" "$shipped_mirror_dir/"
    fi
    copied=$((copied + 1))
  done < <(printf '%s\n' "$resolved_conditionals" | sort -u)
  if (( copied == 0 )); then
    echo "ERROR: pruned mirror selection is empty; refusing to ship a mirror" >&2
    echo "       with no packages (linux-t2 alone should always resolve)" >&2
    exit 1
  fi
  echo "Pruned shipped mirror carries $copied conditional package files."

  # Fresh db over exactly the shipped files, same as the full-mirror repo-add.
  repo-add "$shipped_mirror_dir/offline.db.tar.gz" "$shipped_mirror_dir/"*.pkg.tar.zst

  # Free the Docker VM disk before mkarchiso doubles the airootfs into work/.
  rm -rf "$rootfs_dir" "$rootfs_pacman_conf"
}

# What ships at the airootfs mirror path is now always a real directory built
# per-variant: the pruned conditional closure (image builds) or a full copy of
# the download cache (legacy builds — the cache is no longer mounted at this
# path, so shipping the full mirror is an explicit ~3GB copy).
shipped_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$shipped_mirror_dir"

if [[ $OMARCHY_ROOTFS_IMAGE == "1" ]]; then
  build_rootfs_image
else
  echo "OMARCHY_ROOTFS_IMAGE=0: shipping the full offline mirror, no rootfs image."
  cp -a "$offline_mirror_dir/." "$shipped_mirror_dir/"

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
fi

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO.
mkarchiso -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
