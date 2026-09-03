#!/usr/bin/env bash
# The root image path: the layout gate (a config the image cannot land on
# fails before the disk is touched), the mount-table capture and its replay
# options, and the destructive subvolume dance — received at the top level,
# snapshotted, swapped in for @ with the layout unmounted, layout replayed.
# Successor to the former Python orchestrator's root-image tests.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

btrfs_root_layout() {
  jq -n '{disk_config: {device_modifications: [{partitions: [
    {fs_type: "fat32", mountpoint: "/boot"},
    {fs_type: "btrfs", btrfs: [{name: "@", mountpoint: "/"}, {name: "@home", mountpoint: "/home"}]}
  ]}]}}'
}

section 'layout gate'
fresh_target
CTX_USER_CONFIGURATION=$(btrfs_root_layout)
run_phase verify_root_image_layout
check 'btrfs @ root accepted' eq "$?" 0

CTX_USER_CONFIGURATION=$(jq -n '{disk_config: {device_modifications: [{partitions: [{fs_type: "ext4", mountpoint: "/"}]}]}}')
run_phase verify_root_image_layout
check 'ext4 root refused' test "$?" -ne 0
check 'names the @ requirement' contains "$(cat "$ERR")" 'btrfs @ subvolume'

CTX_USER_CONFIGURATION=$(jq -n '{disk_config: {device_modifications: [{partitions: [{fs_type: "btrfs", btrfs: [{name: "@root", mountpoint: "/"}]}]}]}}')
run_phase verify_root_image_layout
check 'non-@ subvolume refused' test "$?" -ne 0

CTX_USER_CONFIGURATION=$(btrfs_root_layout | jq '.disk_config.lvm_config = {vols: []}')
run_phase verify_root_image_layout
check 'LVM refused' test "$?" -ne 0
check 'names LVM' contains "$(cat "$ERR")" 'LVM'

section 'replay options drop only subvolid'
check 'subvolid dropped, order kept' eq \
  "$(remount_option_string 'rw,noatime,compress=zstd,subvolid=256,subvol=/@')" \
  'rw,noatime,compress=zstd,subvol=/@'
check 'no subvolid is a no-op' eq "$(remount_option_string 'rw,subvol=/@home')" 'rw,subvol=/@home'

section 'target mount capture'
fresh_target
findmnt() {
  record "findmnt $*"
  jq -n --arg t "$CTX_TARGET" '{filesystems: [
    {target: $t, source: "/dev/vda2[/@]", fstype: "btrfs", options: "rw,subvolid=256,subvol=/@", children: [
      {target: ($t + "/home"), source: "/dev/vda2[/@home]", fstype: "btrfs", options: "rw,subvol=/@home"},
      {target: ($t + "/boot"), source: "/dev/vda1", fstype: "vfat", options: "rw,umask=0077"}
    ]}
  ]}'
}
run_phase root_image_target_mounts
check 'valid layout accepted' eq "$?" 0
root_image_target_mounts
check 'device stripped of subvol suffix' eq "$RIMG_DEVICE" /dev/vda2
check 'parents before children' eq "$(jq -r '.[].target' <<<"$RIMG_MOUNTS_JSON" | tr '\n' ' ')" \
  "$CTX_TARGET $CTX_TARGET/home $CTX_TARGET/boot "

findmnt() {
  record "findmnt $*"
  jq -n --arg t "$CTX_TARGET" '{filesystems: [{target: $t, source: "/dev/vda2", fstype: "ext4", options: "rw"}]}'
}
run_phase root_image_target_mounts
check 'non-btrfs root refused' test "$?" -ne 0

findmnt() {
  record "findmnt $*"
  jq -n --arg t "$CTX_TARGET" '{filesystems: [{target: $t, source: "/dev/vda2[/@data]", fstype: "btrfs", options: "rw,subvol=/@data"}]}'
}
run_phase root_image_target_mounts
check 'non-@ root refused' test "$?" -ne 0

section 'the receive pipeline'
# Driven for real: the actual zstd decompresses the outer layer, only the
# receive end is stubbed. What matters is the round trip and that a failure's
# headline names the stage that broke the pipe.
fresh_target
printf 'extents and framing' >"$TMP/payload"
zstd -q -15 --long=27 -o "$TMP/stream.zst" "$TMP/payload"
btrfs() { cat >"$TMP/received"; }
run_phase receive_root_image "$TMP/top" "$TMP/stream.zst"
check 'a good stream receives' eq "$?" 0
check 'decompressed bytes reach the receive end' eq "$(cat "$TMP/received")" 'extents and framing'

printf 'not a zstd stream' >"$TMP/garbage.zst"
btrfs() { cat >/dev/null; }
run_phase receive_root_image "$TMP/top" "$TMP/garbage.zst"
check 'a broken outer layer fails the phase' test "$?" -ne 0
check 'and names the decompression stage' contains "$(cat "$ERR")" 'root image decompression failed'

btrfs() { cat >/dev/null; return 1; }
run_phase receive_root_image "$TMP/top" "$TMP/stream.zst"
check 'a dying receive fails the phase' test "$?" -ne 0
check 'and names the receive stage' contains "$(cat "$ERR")" 'btrfs receive failed'

# Both ends broken at once: which of them broke the pipe cannot be read off
# the exit codes, so the headline must name both instead of picking one and
# sending the reader after the wrong stage.
run_phase receive_root_image "$TMP/top" "$TMP/garbage.zst"
check 'two dead stages fail the phase' test "$?" -ne 0
check 'and the headline names both' contains "$(cat "$ERR")" \
  'root image decompression and btrfs receive both failed'

section 'the subvolume dance'
fresh_target
ROOT_IMAGE_STREAM="$TMP/omarchy-root.btrfs.zst"
printf 'stream-bytes' >"$ROOT_IMAGE_STREAM"
findmnt() {
  jq -n --arg t "$CTX_TARGET" '{filesystems: [
    {target: $t, source: "/dev/vda2[/@]", fstype: "btrfs", options: "rw,subvolid=256,subvol=/@", children: [
      {target: ($t + "/home"), source: "/dev/vda2[/@home]", fstype: "btrfs", options: "rw,subvol=/@home"}
    ]}
  ]}'
}
mount() { record "mount $*"; }
umount() { record "umount $*"; }
systemd-mount() { record "systemd-mount $*"; }
systemd-umount() { record "systemd-umount $*"; }
umount_tree() { record "umount_tree $1"; }
btrfs() { record "btrfs $*"; }
mv() { record "mv $*"; }
receive_root_image() { record "receive $1"; }
systemd-machine-id-setup() { record "machine-id $*"; }
target_has_package() { record "has_package $2"; }
omarchy_runtime_package() { echo omarchy; }
omarchy_settings_package() { echo omarchy-settings; }
omarchy_nvim_package() { echo omarchy-nvim; }
run_phase install_root_image
check 'phase ok' eq "$?" 0
check 'received at the top level, swapped in with the layout down' eq "$(calls | tr '\n' ';')" \
"systemd-mount --quiet -o subvolid=5 --property=PartOf=omarchy-install.target /dev/vda2 $CTX_STATE_DIR/image-top;receive $CTX_STATE_DIR/image-top;btrfs subvolume snapshot $CTX_STATE_DIR/image-top/omarchy-root $CTX_STATE_DIR/image-top/@.image;btrfs subvolume delete $CTX_STATE_DIR/image-top/omarchy-root;umount_tree $CTX_TARGET;btrfs subvolume delete $CTX_STATE_DIR/image-top/@;mv $CTX_STATE_DIR/image-top/@.image $CTX_STATE_DIR/image-top/@;mount -t btrfs -o rw,subvol=/@ /dev/vda2 $CTX_TARGET;mount -t btrfs -o rw,subvol=/@home /dev/vda2 $CTX_TARGET/home;systemd-umount --quiet $CTX_STATE_DIR/image-top;has_package limine;has_package omarchy-keyring;has_package omarchy;has_package omarchy-settings;has_package omarchy-nvim;machine-id --root=$CTX_TARGET;"

section 'a missing required package fails the phase'
reset_calls
target_has_package() { record "has_package $2"; [[ $2 != omarchy-keyring ]]; }
run_phase install_root_image
check 'phase failed' test "$?" -ne 0
check 'names the package' contains "$(cat "$ERR")" 'omarchy-keyring'

finish
