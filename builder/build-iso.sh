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

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
# Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
# so this container can be months behind the mirror it installs from. A plain
# -Sy install is then a partial upgrade — new packages linked against a glibc
# the container doesn't have yet.
pacman --noconfirm -Syu archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli btrfs-progs

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

# Build locations
build_cache_dir=/var/cache
# The mirror is deliberately NOT under $build_cache_dir/airootfs: what ships is
# the selection staged from it (stage-mirror-files.sh) into its own directory
# in the ISO9660 tree, and anything left in the profile's airootfs would be
# copied into the squashfs as well. This is also the path pacman-offline.conf serves the
# [offline] repo from, at build time and in the live system alike, so the live
# root's pacstrap and the root image's both resolve against it unchanged.
offline_mirror_dir=/var/cache/omarchy/mirror/offline
mkdir -p "$build_cache_dir" "$offline_mirror_dir"

# Seed from the official Arch releng profile.
cp -r /archiso/configs/releng/* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# We rely on the global CDN; drop reflector.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# releng runs sshd as a boot daemon; the live ISO answers on 22 via the
# profile's socket-activated sshd.socket instead — a per-connection sshd@
# that also defers host key generation to the first connection. Same auth
# behavior (releng's sshd_config drop-in stays), different start mechanism.
rm -f "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"

# Bring in our archiso profile additions.
cp -r /configs/* "$build_cache_dir/"

# The installer library: archinstall-bash (vendored in-tree), the bash port of
# archinstall the orchestrator sources (see orchestrator/archinstall.sh).
mkdir -p "$build_cache_dir/airootfs/usr/share/archinstall-bash"
cp -r /archinstall-bash/bin /archinstall-bash/lib /archinstall-bash/LICENSE "$build_cache_dir/airootfs/usr/share/archinstall-bash/"
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
  # A rebuild of the same revision produces the same filename with different
  # bytes. pacman consults /var/cache/pacman/pkg (the host's cache, kept across
  # --keep-pkg-cache builds) before the mirror, and a stale copy from an
  # earlier build fails the checksum against the mirror's fresh db.
  for local_package_name in \
    "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"; do
    rm -f /var/cache/pacman/pkg/"$local_package_name"-*.pkg.tar.zst{,.sig}
  done
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
#
# kbd used to arrive as a dependency of releng's archinstall package, which is
# dropped below: localectl's keymap list (archinstall-bash validates the layout
# with it) is kbd's. The filesystem tools archinstall depended on are listed
# by releng in their own right. Nothing on the live ISO needs Python.
arch_packages=(linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted kbd)
printf '%s\n' "${arch_packages[@]}" >> "$build_cache_dir/packages.x86_64"

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
# archinstall (Python) goes too: the ISO installs with archinstall-bash, and
# the Python package would only add pyparted, textual and friends to the
# cold-booted squashfs. So do cloud-init, reflector and clonezilla, the other
# releng packages that pull Python in: the autoinstall drive is read by
# omarchy-cidata-load (bash), reflector's service is removed above since the
# install is offline, and nothing here clones disks (the partition tools
# clonezilla depends on — parted, gptfdisk, ntfs-3g, dosfstools, partclone —
# are listed by releng in their own right and stay). With those gone the
# live ISO carries no Python.
#
# Anchored so linux-t2 and linux-firmware are untouched.
sed -i -E '/^(linux|broadcom-wl|archinstall|cloud-init|reflector|clonezilla)$/d' "$build_cache_dir/packages.x86_64"

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
    # The root image is pacstrapped from the pruned mirror, so its packages
    # must be in the keep-set even when nothing in the lists depends on them.
    grep -hv '^#\|^$' /builder/image.packages
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

rebuild_offline_repo_db() {
  rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
  repo-add -q "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst
}

# Resolve the exact filenames chosen by the same synced package databases used
# for the download. Pruning by this transaction (rather than merely keeping the
# newest version of every cached package name) removes packages that have left
# the lists or dependency closure, such as an old Electron major version. This
# is the build cache: it keeps the whole closure so the next build downloads
# nothing; what the ISO ships is decided below.
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

# Packages that differ per machine and therefore stay out of the root image:
# the installer pacstraps them on the target after unpacking the image, and
# omarchy-apply-system installs more from omarchy-other.packages as the
# hardware dictates. Everything else the target gets is in the image.
hardware_packages=(linux linux-t2 amd-ucode intel-ucode sof-firmware alsa-firmware tailscale)

mapfile -t image_packages < <(
  {
    grep -hv '^#\|^$' /builder/archinstall.packages
    grep -hv '^#\|^$' /builder/image.packages
    # The shipped copy, which is what the install reads too.
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u | grep -Fxv "${hardware_packages[@]/#/-e}"
)

# pacstrap resolves the image against the offline repo and, with CacheDir on
# the mirror itself, extracts the package files in place instead of copying
# several GiB into a cache first (the same trick the installer's bind mount
# plays on the target).
image_pacman_conf="$build_cache_dir/pacman-root-image.conf"
sed "/^\[options\]/a CacheDir = /var/cache/omarchy/mirror/offline/" \
  "$build_cache_dir/pacman-offline.conf" >"$image_pacman_conf"

# The stream ships as a plain file in the ISO9660 tree next to airootfs.sfs,
# not inside the squashfs: mkarchiso packs its work/iso directory as is, so a
# file seeded there ends up on the ISO with the boot records intact. Read
# straight off the boot medium it skips squashfs's per-block copy (~10% off
# the unpack), mkarchiso no longer copies 3GB into the squashfs, and the
# image can be pulled out of the ISO with any ISO9660 tool. The live system
# finds it at /run/archiso/bootmnt/<install_dir>/<arch>/.
#
# profiledef.sh cannot be sourced standalone (its file_permissions needs
# mkarchiso's declare -A first); read the two values it sets instead.
iso_subdir="$(sed -n 's/^install_dir="\(.*\)"$/\1/p' "$build_cache_dir/profiledef.sh")/$(sed -n 's/^arch="\(.*\)"$/\1/p' "$build_cache_dir/profiledef.sh")"
[[ $iso_subdir == */x86_64 ]] || { echo "ERROR: could not read install_dir/arch from profiledef.sh: '$iso_subdir'" >&2; exit 1; }
iso_payload_dir="$build_cache_dir/work/iso/$iso_subdir"
root_image_stream="$iso_payload_dir/omarchy-root.btrfs.zst"
mkdir -p "$iso_payload_dir"
# Builds before the move left the stream (and, briefly, its checksum) in the
# persistent build cache, where they would ship inside the squashfs alongside
# the new one.
rm -f "$build_cache_dir/airootfs/var/cache/omarchy/rootfs/omarchy-root.btrfs"*

image_localdb=/tmp/omarchy-root-image-localdb
echo "[timing] root image start $(date +%s)"
OMARCHY_IMAGE_LOCALDB_COPY="$image_localdb" \
  bash /builder/build-root-image.sh "$image_pacman_conf" "$root_image_stream" "${image_packages[@]}"
echo "[timing] root image end $(date +%s)"

# What the ISO ships out of this mirror. mkarchiso pacstraps the live root from
# the complete mirror at build time, but at install time only packages the
# root image does not already hold can ever be downloaded from it: the
# per-machine packages, and whatever omarchy-apply-system adds from
# omarchy-other.packages. So the shipped-package list below and
# stage-mirror-files.sh keep every package file the image already provides,
# at the same version, out of the medium's copy of the mirror. The repo db
# stays complete on purpose: the hardware
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
shipped_list="$build_cache_dir/airootfs/usr/share/omarchy-iso/offline-mirror.shipped"
awk -F'\t' '
  NR == FNR { image[$1 "\t" $2] = 1; next }
  !(($1 "\t" $2) in image) { print $3 }
' <(image_package_index) <(mirror_package_index) | sort -u >"$shipped_list"
# grep -c exits 1 on no match; the count check below wants the 0.
shipped_count=$(grep -c . "$shipped_list" || true)
mirror_count=$(mirror_package_index | wc -l)
if (( shipped_count == 0 || shipped_count >= mirror_count )); then
  echo "ERROR: the shipped-mirror selection looks wrong: $shipped_count of $mirror_count packages" >&2
  exit 1
fi
echo "Shipping $shipped_count of $mirror_count mirror packages; the root image provides the rest."

# Ship the selection as ordinary files in their own directory in the ISO9660
# tree, beside the root image and outside the squashfs. The live system
# bind-mounts that directory over /var/cache/omarchy/mirror/offline, where the
# mirror has always been, so the [offline] repo, the installer's bind mount
# onto the target package cache, and the media diagnosis all address it by an
# unchanged path.
mirror_files_dir="$iso_payload_dir/mirror"
echo "[timing] mirror files start $(date +%s)"
bash /builder/stage-mirror-files.sh "$offline_mirror_dir" "$shipped_list" "$mirror_files_dir"
echo "[timing] mirror files end $(date +%s)"

# The checksum for the one thing on this medium nothing else can check: the
# root image stream, which btrfs receive takes on trust. Written beside it, as
# <stream>.sha256, and verified at boot by omarchy-root-image-verify.
#
# Nothing else is listed. The mirror's packages carry their checksums in the
# repo database, one %SHA256SUM% per desc record -- the number pacman validates
# against as it installs, and the one omarchy-verify-package reads for the
# handful this machine will install. The databases carry their own: they are
# gzip, so a damaged one fails its CRC on the first read rather than handing
# out records that look fine.
(cd "$iso_payload_dir" && sha256sum "${root_image_stream##*/}" >"$root_image_stream.sha256")

# Bound the boot-time hash: Type=oneshot units are exempt from systemd's
# default start timeout, so a stick that stalls reads instead of returning an
# error would hang omarchy-root-image-verify.service -- and with it the
# install -- forever. Budget a floor of 2 MiB/s over the stream, which is all
# that unit hashes (a USB 2.0 port sustains ~30 MB/s; the margin covers the
# idle-class
# hash yielding to the live system's page-ins) plus ten minutes of slack for
# boot. On timeout systemd sets Result=timeout and omarchy-wait-verify
# turns that into a "medium too slow" message instead of the corrupt-medium one.
payload_bytes=$(stat -c %s "$root_image_stream")
verify_dropin_dir="$build_cache_dir/airootfs/etc/systemd/system/omarchy-root-image-verify.service.d"
mkdir -p "$verify_dropin_dir"
cat >"$verify_dropin_dir/50-size-timeout.conf" <<EOF
# Generated by build-iso.sh: 2 MiB/s floor over the $payload_bytes-byte root
# image stream, which is what the boot-time verify hashes.
[Service]
TimeoutStartSec=$((payload_bytes / (2 * 1024 * 1024) + 600))
EOF

# The same budget for the mirror verification the pre-flight gate waits on,
# over the package archives it hashes.
mirror_bytes=$(find "$mirror_files_dir" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' -printf '%s\n' |
  awk '{ total += $1 } END { print total + 0 }')
mirror_dropin_dir="$build_cache_dir/airootfs/etc/systemd/system/omarchy-mirror-verify.service.d"
mkdir -p "$mirror_dropin_dir"
cat >"$mirror_dropin_dir/50-size-timeout.conf" <<EOF
# Generated by build-iso.sh: 2 MiB/s floor over the $mirror_bytes bytes of
# package archives omarchy-verify-mirror hashes.
[Service]
TimeoutStartSec=$((mirror_bytes / (2 * 1024 * 1024) + 600))
EOF

# And for the image-unpack phase unit: btrfs receive reads the same stream
# off the medium, so the same floor bounds it.
image_dropin_dir="$build_cache_dir/airootfs/etc/systemd/system/omarchy-install-image.service.d"
mkdir -p "$image_dropin_dir"
cat >"$image_dropin_dir/50-size-timeout.conf" <<EOF
# Generated by build-iso.sh: 2 MiB/s floor over the $payload_bytes-byte root
# image stream omarchy-install-image receives.
[Service]
TimeoutStartSec=$((payload_bytes / (2 * 1024 * 1024) + 600))
EOF


# The mount point itself: an empty directory in the profile's airootfs, since
# nothing populates it there any more. customize_airootfs.sh fails the build if
# anything does.
mkdir -p "$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"

# Denominator for the install dashboard's progress bar: what the image holds
# plus the kernel's closure on top of it, resolved against the image's own
# local db with the pruned mirror, which is the question the installer's delta
# pacstrap asks. Plus one for the microcode package every real machine gets.
# phases.sh records expected and actual in the timing JSON, so drift shows up
# in acceptance runs.
resolve_expected_packages() {
  local resolve_root=/tmp/omarchy-expected-packages
  local image_count resolved

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
  resolved="$(pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' --needed linux)" || return 1

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

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Build the ISO.
echo "[timing] mkarchiso start $(date +%s)"
mkarchiso -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"
echo "[timing] mkarchiso end $(date +%s)"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi
