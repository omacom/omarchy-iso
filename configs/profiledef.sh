#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="omarchy"
iso_label="OMARCHY_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Omarchy <https://omarchy.org>"
iso_application="Omarchy Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman-offline.conf"
airootfs_image_type="squashfs"
# The offline mirror is no longer in here at all: it ships as ordinary files in
# their own directory in the ISO9660 tree, beside the root image (see
# builder/stage-mirror-files.sh). Its archives are already zstd-compressed, so
# the squashfs had to store them uncompressed anyway, and the outer layer only
# bought pacman a copy through squashfs's per-block path while hashing and
# extracting every package during installation.
#
# What remains in the live root is zstd rather than xz. Squashfs decompresses
# on the page-fault path through a single stream (CONFIG_SQUASHFS_DECOMP_SINGLE),
# where xz manages ~100MB/s against zstd's ~900MB/s, and the live root is read
# cold on every boot: kernel, plymouth, systemd, archinstall-bash, gum. The
# whole ISO grows well under a percent for it, and dropping the x86 BCJ filter
# also removes one of the blockers listed in plans/aarch64-support.md.
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' '19'
  '-b' '1M'
)
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/configurator"]="0:0:755"
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/omarchy-cidata-load"]="0:0:755"
  ["/usr/local/bin/omarchy-prefetch"]="0:0:755"
  ["/usr/local/bin/omarchy-stall-watchdog"]="0:0:755"
  ["/usr/local/bin/omarchy-wait-verify"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-cleanup-disk"]="0:0:755"
  ["/usr/local/bin/omarchy-release-install-target"]="0:0:755"
  ["/usr/local/bin/omarchy-install-dashboard"]="0:0:755"
  ["/usr/local/bin/omarchy-install-diagnose-media"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-install"]="0:0:755"
  ["/usr/local/bin/omarchy-verify-mirror"]="0:0:755"
  # Copied in by build-iso.sh from the vendored archinstall-bash tree; mkarchiso
  # drops file modes on copy, so the executables must be declared here too.
  ["/usr/share/archinstall-bash/bin/archinstall"]="0:0:755"
  ["/usr/share/omarchy-iso/orchestrator/run-phase"]="0:0:755"
  ["/usr/local/bin/omarchy-cpu-governor"]="0:0:755"
  # Mount point only; var-cache-omarchy-mirror-offline.mount puts the mirror
  # image over it at boot.
  ["/var/cache/omarchy/mirror/offline/"]="0:0:755"
)
