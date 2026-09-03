#!/usr/bin/env bash
# Unit tests for the configuration parser, partition planning and kernel
# parameter generation. Runs unprivileged: block-device probes are stubbed.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export ARCHINSTALL_LOG_DIR=${TMPDIR:-/tmp}/archinstall-bash-test-$$
# shellcheck disable=SC1091
source "$here/../lib/archinstall.sh"

failures=0
assert_eq() {
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

# Stubs: a 10 GiB disk with 512-byte sectors, UEFI firmware, no live keymap.
disk_size_bytes() { printf '%s' $((10 * 1024 * 1024 * 1024)); }
disk_sector_size() { printf '512'; }
sysinfo_has_uefi() { return 0; }
locale_get_kb_layout() { :; }
machine_arch() { printf 'x86_64'; }

config_load "$here/../examples/omarchy-full-disk.json" "$here/../examples/omarchy-credentials.json"

assert_eq 'hostname' "$CFG_HOSTNAME" omarchy
assert_eq 'timezone' "$CFG_TIMEZONE" Europe/Oslo
assert_eq 'kernels' "${CFG_KERNELS[*]}" linux
assert_eq 'keymap' "$CFG_LOCALE_KB" no
assert_eq 'bootloader' "$CFG_BOOTLOADER" limine
assert_eq 'swap' "$CFG_SWAP_ENABLED" true
assert_eq 'parallel downloads (deprecated key)' "$CFG_HAS_PACMAN_CONFIG/$CFG_PARALLEL_DOWNLOADS" true/8
assert_eq 'network' "$CFG_NETWORK_TYPE" iso
assert_eq 'audio (deprecated key)' "$CFG_HAS_APP_CONFIG/$CFG_AUDIO" true/pipewire
assert_eq 'custom servers' "${#CFG_MIRROR_CUSTOM_SERVERS[@]}" 3
assert_eq 'packages' "${CFG_PACKAGES[*]}" 'base-devel git omarchy-keyring omarchy-settings omarchy'
assert_eq 'user' "${USER_NAME[*]}/${USER_SUDO[*]}" jonny/true
assert_eq 'root password from creds' "${CFG_ROOT_ENC_PASSWORD:0:4}" '$y$j'

assert_eq 'disk config type' "$DISK_CONFIG_TYPE" default_layout
assert_eq 'device' "${DEV_PATH[*]}/${DEV_WIPE[*]}" /dev/loop0/true
assert_eq 'partition count' "${#PART_DEV[@]}" 2
assert_eq 'esp flags' "${PART_FLAGS[0]}" 'boot esp'
assert_eq 'esp size' "${PART_START[0]}+${PART_LENGTH[0]}" '1048576+2147483648'
assert_eq 'root subvols' "${PART_SUBVOLS[1]}" '@=/ @home=/home @log=/var/log @pkg=/var/cache/pacman/pkg'
assert_eq 'root subvol name' "$(part_root_subvol 1)" '@'
assert_eq 'root detection' "$(installer_get_root)" 1
assert_eq 'efi detection' "$(installer_get_efi_partition)" 0
assert_eq 'boot detection' "$(installer_get_boot_partition)" 0
assert_eq 'has default btrfs vols' "$(disk_has_default_btrfs_vols && echo yes)" yes
assert_eq 'encryption' "$ENC_TYPE/${ENC_PARTS[*]}/$ENC_ITER_TIME/$ENC_PASSWORD" luks/1/2000/hunter2
assert_eq 'mapper name' "$(part_mapper_name 1)" root
assert_eq 'sorted partitions' "$(disk_partition_indexes_sorted 0 | tr '\n' ' ')" '0 1 '
bad=$(jq '.disk_config.device_modifications[0].wipe = false' "$here/../examples/omarchy-full-disk.json")
out=$( (CONFIG_JSON=$(jq -c -s '.[0] + .[1]' <(printf '%s' "$bad") "$here/../examples/omarchy-credentials.json"); config_parse) 2>&1)
assert_eq 'wipe:false refused' "${out%%;*}" 'error: device_modifications without wipe: true (adding partitions to an existing table) is not supported by this port'
bad=$(jq '.disk_config.disk_encryption.partitions = ["ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d"]' "$here/../examples/omarchy-full-disk.json")
out=$( (CONFIG_JSON=$(jq -c -s '.[0] + .[1]' <(printf '%s' "$bad") "$here/../examples/omarchy-credentials.json"); config_parse) 2>&1)
assert_eq 'non-root encryption refused' "${out%% (*}" 'error: only the root partition may be encrypted in this port'

assert_eq 'sfdisk line esp' "$(fs_sfdisk_line 0 512 gpt)" 'start=2048, size=4194304, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
assert_eq 'sfdisk line root' "$(fs_sfdisk_line 1 512 gpt)" 'start=4196352, size=12580864, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709'
assert_eq 'sfdisk line root (4Kn)' "$(fs_sfdisk_line 1 4096 gpt)" 'start=524544, size=1572608, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709'
assert_eq 'sfdisk line esp (mbr)' "$(fs_sfdisk_line 0 512 dos)" 'start=2048, size=4194304, type=c, bootable'

installer_init /mnt linux
PART_PARTUUID[1]=11111111-2222-3333-4444-555555555555
PART_UUID[1]=66666666-7777-8888-9999-000000000000
INST_ZRAM_ENABLED=1
assert_eq 'kernel params (encrypted root)' "$(installer_get_kernel_params 1)" \
  'cryptdevice=PARTUUID=11111111-2222-3333-4444-555555555555:root root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs'
assert_eq 'kernel params (no id_root, uuid)' "$(installer_get_kernel_params 1 0 0)" \
  'cryptdevice=UUID=66666666-7777-8888-9999-000000000000:root zswap.enabled=0 rootfstype=btrfs'
ENC_PARTS=()
assert_eq 'kernel params (plain root)' "$(installer_get_kernel_params 1)" \
  'root=PARTUUID=11111111-2222-3333-4444-555555555555 zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs'
assert_eq 'mount option merge' "$(installer_merge_options 'compress=zstd' subvol=@home compress=zstd)" 'compress=zstd,subvol=@home'
assert_eq 'esp mount options' "$(installer_merge_options '' fmask=0077 dmask=0077)" 'fmask=0077,dmask=0077'
assert_eq 'base packages' "${INST_BASE_PACKAGES[*]}" 'base sudo linux-firmware mkinitcpio linux'
installer_prepare_fs_type btrfs
installer_prepare_encrypt
assert_eq 'btrfs-progs added' "${INST_BASE_PACKAGES[*]}" 'base sudo linux-firmware mkinitcpio linux btrfs-progs'
assert_eq 'fstrim disabled on btrfs' "$INST_DISABLE_FSTRIM" 1
assert_eq 'encrypt hook position' "${INST_HOOKS[*]}" 'base systemd autodetect microcode modconf kms keyboard sd-vconsole block encrypt filesystems fsck'
assert_eq 'mirrorlist custom servers' "$(mirrors_custom_servers_config | head -n2 | tr '\n' '|')" '## Custom Servers|Server = https://mirror.omarchy.org/$repo/os/$arch|'

# Validation failures
bad=$(jq '.disk_config.device_modifications[0].partitions[1].start.value = 2147483648' "$here/../examples/omarchy-full-disk.json")
out=$( (CONFIG_JSON=$(jq -c -s '.[0] + .[1]' <(printf '%s' "$bad") "$here/../examples/omarchy-credentials.json"); config_parse) 2>&1)
assert_eq 'overlap detected' "$out" 'error: Partitions overlap'
bad=$(jq '.disk_config.device_modifications[0].partitions[1].size.value = 8589934592' "$here/../examples/omarchy-full-disk.json")
out=$( (CONFIG_JSON=$(jq -c -s '.[0] + .[1]' <(printf '%s' "$bad") "$here/../examples/omarchy-credentials.json"); config_parse) 2>&1)
assert_eq 'gpt backup header protected' "$out" 'error: Partition overlaps backup GPT header'
out=$( (config_load "$here/../examples/omarchy-full-disk.json") 2>&1)
assert_eq 'missing encryption password refused' "$out" 'error: disk encryption requested but no encryption_password supplied (user_credentials.json)'

# Deprecated plaintext credential keys are hashed
creds=$(mktemp)
printf '{"!root-password": "secret", "!users": [{"username": "t", "!password": "pw", "sudo": false}]}' >"$creds"
config_load "$here/../examples/omarchy-pre-mounted.json" "$creds" 2>/dev/null || true
rm -f "$creds"
assert_eq 'plaintext root password hashed' "${CFG_ROOT_ENC_PASSWORD:0:1}" '$'
assert_eq 'plaintext user password hashed' "${USER_NAME[*]}/${USER_ENC_PASSWORD[0]:0:1}/${USER_SUDO[*]}" 't/$/false'
assert_eq 'pre-mount type' "$DISK_CONFIG_TYPE/$DISK_MOUNTPOINT" pre_mounted_config//mnt

# The streaming runner under a caller's -euo pipefail: output reaches stdout
# and the log, the command's status is preserved, and nothing references $!
# (bash does not set it for process substitutions).
out=$(bash -euo pipefail -c '
  source "$1/lib/archinstall.sh"
  sys_cmd_peek sh -c "echo streamed; exit 3" && echo "rc=0" || echo "rc=$?"
  sys_cmd_peek echo fine && echo "rc=0"
' _ "$here/.." 2>&1)
assert_eq 'sys_cmd_peek under set -euo pipefail' "$(tr '\n' '|' <<<"$out")" 'streamed|rc=3|fine|rc=0|'
assert_eq 'sys_cmd_peek logs the output' "$(grep -cx 'streamed' "$ARCHINSTALL_LOG_DIR/install.log")" 1

rm -rf "$ARCHINSTALL_LOG_DIR"
if ((failures)); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
printf 'all tests passed\n'
