#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="${OMARCHY_ISO_NAME:-omarchy}"
iso_label="OMARCHY_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Omarchy <https://omarchy.org>"
iso_application="Omarchy Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
# build-iso.sh exports OMARCHY_ARCH into the mkarchiso environment. aarch64
# firmware is UEFI-only, so the BIOS syslinux boot mode is dropped there.
arch="${OMARCHY_ARCH:-x86_64}"
if [[ $arch == aarch64 ]]; then
  bootmodes=('uefi.grub')
else
  bootmodes=('bios.syslinux' 'uefi.grub')
fi
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
# linux-aarch64 cannot mount a zstd-compressed SquashFS image.
if [[ $arch == aarch64 ]]; then
  _airootfs_comp=('-comp' 'xz' '-Xbcj' 'arm')
else
  _airootfs_comp=('-comp' 'zstd' '-Xcompression-level' '19')
fi
airootfs_image_tool_options=(
  "${_airootfs_comp[@]}"
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
  ["/usr/local/bin/omarchy-upload-log"]="0:0:755"
  ["/usr/local/sbin/omarchy-n1x-live-probe"]="0:0:755"
  ["/var/cache/omarchy/mirror/offline/"]="0:0:775"
)

# Staged into the airootfs by build-iso.sh for Snapdragon and generic aarch64
# media only. The N1x image boots its own kernel through GRUB.
if [[ $arch == aarch64 && ${OMARCHY_MEDIA_TARGET:-aarch64/snapdragon} != aarch64/n1x ]]; then
  file_permissions["/etc/mkinitcpio.conf.d/zz-aarch64-live.conf"]="0:0:644"
  file_permissions["/etc/mkinitcpio.d/linux.preset"]="0:0:644"
  file_permissions["/root/customize_airootfs.sh"]="0:0:755"
  file_permissions["/root/live-uki.sh"]="0:0:755"
  if [[ ${OMARCHY_MEDIA_TARGET:-aarch64/snapdragon} == aarch64/snapdragon ]]; then
    file_permissions["/usr/local/bin/omarchy-live-dsp"]="0:0:755"
  fi
fi
