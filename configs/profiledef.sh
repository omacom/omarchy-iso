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
# Package archives in the offline mirror are already zstd-compressed. Storing
# them in an outer stream saves little space but makes pacman decompress the
# outer layer while hashing and extracting every package during installation.
#
# Everything else in the live root is zstd rather than xz. Squashfs decompresses
# on the page-fault path through a single stream (CONFIG_SQUASHFS_DECOMP_SINGLE),
# where xz manages ~100MB/s against zstd's ~900MB/s, and the live root is read
# cold on every boot: kernel, plymouth, systemd, python, archinstall, gum. The
# whole ISO grows well under a percent for it, and dropping the x86 BCJ filter
# also removes one of the blockers listed in plans/aarch64-support.md.
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' '19'
  '-b' '1M'
  '-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'
)
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/configurator"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/omarchy-cidata-load"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-cleanup-disk"]="0:0:755"
  ["/usr/local/bin/omarchy-install-dashboard"]="0:0:755"
  ["/usr/local/bin/omarchy-install-diagnose-media"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-install"]="0:0:755"
  ["/usr/local/bin/omarchy-luks-pbkdf-memory"]="0:0:755"
  ["/usr/local/bin/omarchy-upload-log"]="0:0:755"
  ["/var/cache/omarchy/mirror/offline/"]="0:0:775"
)
