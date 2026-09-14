#!/usr/bin/env bash
# stage_provisioning_state, configure_login, the deferred-provisioning SSH
# staging and create_factory_snapshot against a temp target.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

NODE_PACKAGES_DIR="$TMP/opt-packages"
node_tarball() { mkdir -p "$NODE_PACKAGES_DIR"; printf node >"$NODE_PACKAGES_DIR/node-v24.0.0-linux-x64.tar.gz"; }
runtime_support() {
  mkdir -p "$CTX_TARGET/usr/share/omarchy/install/provisioning" "$CTX_TARGET/usr/bin"
  printf '[Unit]\n' >"$CTX_TARGET/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  printf '#!/bin/bash\n' >"$CTX_TARGET/usr/bin/omarchy-provision-owner"
}
provisioning_dir() { printf '%s' "$CTX_TARGET/var/lib/omarchy/provisioning"; }
fails_with() { local fn=$1; shift; run_phase "$fn"; local rc=$?; ((rc != 0)) && contains "$(cat "$ERR")" "$1"; }
arch-chroot() { record "arch-chroot $*"; return 0; }

section 'normal install stages only the Node tarball'
fresh_target; node_tarball; CTX_DEFER_PROVISIONING=false
run_phase stage_provisioning_state
check 'phase ok' eq "$?" 0
check 'tarball stashed' test -e "$(provisioning_dir)/packages/node-v24.0.0-linux-x64.tar.gz"
check 'not armed' test ! -e "$(provisioning_dir)/pending"
check 'no unit' test ! -e "$CTX_TARGET/etc/systemd/system/omarchy-provision-owner.service"

section 'deferred provisioning against a runtime without support fails clearly'
fresh_target; node_tarball
check 'error' fails_with stage_provisioning_state 'does not ship'

section 'missing Node tarball fails'
fresh_target; rm -rf "$NODE_PACKAGES_DIR"; runtime_support
check 'deferred' fails_with stage_provisioning_state 'Node tarball'
fresh_target; CTX_DEFER_PROVISIONING=false
check 'normal installs too' fails_with stage_provisioning_state 'Node tarball'

section 'deferred provisioning arms first-boot setup'
fresh_target; node_tarball; runtime_support
run_phase stage_provisioning_state
check 'phase ok' eq "$?" 0
check 'pending marker' test -e "$(provisioning_dir)/pending"
check 'unit copied' test -e "$CTX_TARGET/etc/systemd/system/omarchy-provision-owner.service"
link="$CTX_TARGET/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
check 'unit enabled' test -L "$link"
check 'link target' eq "$(readlink "$link")" /etc/systemd/system/omarchy-provision-owner.service
check 'unencrypted: no LUKS staging' test ! -e "$(provisioning_dir)/luks-key"

section 'deferred provisioning encrypted stages LUKS auto-unlock'
fresh_target; node_tarball; runtime_support
CTX_USER_CONFIGURATION='{"disk_config": {"disk_encryption": {"encryption_type": "luks", "encryption_password": "throwaway-secret"}}}'
run_phase stage_provisioning_state
check 'phase ok' eq "$?" 0
check 'luks-key byte for byte' eq "$(cat "$(provisioning_dir)/luks-key"; printf x)" throwaway-secretx
check 'keyfile' eq "$(cat "$CTX_TARGET/etc/omarchy/provisioning.key"; printf x)" throwaway-secretx
check 'keyfile private' eq "$(mode_of "$CTX_TARGET/etc/omarchy/provisioning.key")" 600
check 'cmdline drop-in' contains "$(cat "$CTX_TARGET/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf")" 'cryptkey=rootfs:/etc/omarchy/provisioning.key'
check 'mkinitcpio FILES drop-in' contains "$(cat "$CTX_TARGET/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf")" 'FILES+=(/etc/omarchy/provisioning.key)'

section 'deferred provisioning on a pre-encrypted target without passphrase fails'
fresh_target; node_tarball; runtime_support
CTX_OMARCHY_INSTALL='{"mode": "protected", "defer_provisioning": true, "storage": {"luks_uuid": "abc"}}'
check 'error' fails_with stage_provisioning_state passphrase

section 'configure_login'
fresh_target; CTX_ENCRYPT=true
run_phase configure_login
check 'deferred: sddm conf' test -e "$CTX_TARGET/etc/sddm.conf.d/99-omarchy-login.conf"
check 'deferred: no autologin' test ! -e "$CTX_TARGET/etc/sddm.conf.d/autologin.conf"
check 'deferred: no sddm state' test ! -e "$CTX_TARGET/var/lib/sddm/state.conf"
check 'deferred: sddm enabled' contains "$(calls)" 'systemctl enable sddm.service'
fresh_target; CTX_DEFER_PROVISIONING=false; CTX_ENCRYPT=true; CTX_USERNAME=jeff
run_phase configure_login
check 'encrypted: autologin' contains "$(cat "$CTX_TARGET/etc/sddm.conf.d/autologin.conf")" 'User=jeff'
check 'encrypted: sddm state' contains "$(cat "$CTX_TARGET/var/lib/sddm/state.conf")" 'User=jeff'
fresh_target; CTX_DEFER_PROVISIONING=false; CTX_ENCRYPT=false; CTX_USERNAME=jeff
run_phase configure_login
check 'unencrypted: no autologin' test ! -e "$CTX_TARGET/etc/sddm.conf.d/autologin.conf"

section 'deferred provisioning stages SSH keys for first boot'
fresh_target
printf 'ssh-ed25519 AAAA rig@host\n' >"$TMP/authorized_keys"
CTX_AUTHORIZED_KEYS_PATH="$TMP/authorized_keys"
arch-chroot() {
  record "arch-chroot $*"
  if [[ $2 == ufw ]]; then mkdir -p "$CTX_TARGET/etc/ufw"; printf -- '-A ufw-user-input -p tcp --dport 22 -j ACCEPT\n' >"$CTX_TARGET/etc/ufw/user.rules"; fi
  return 0
}
run_phase configure_ssh_access
check 'phase ok' eq "$?" 0
check 'staged keys' eq "$(cat "$(provisioning_dir)/authorized_keys")" 'ssh-ed25519 AAAA rig@host'
check 'staged keys private' eq "$(mode_of "$(provisioning_dir)/authorized_keys")" 600
check 'no /home yet' test ! -e "$CTX_TARGET/home"
check 'no chown' test -z "$(calls | grep chown || true)"
check 'door still opened' contains "$(calls)" 'systemctl enable sshd.service'

section 'factory snapshot'
FM_FSTYPE=btrfs FM_OPTIONS='rw,noatime,compress=zstd:3,subvol=/@' FM_SOURCE='/dev/mapper/omarchy_root[/@]'
findmnt() { # -no COL path
  record "findmnt $*"
  case $2 in FSTYPE) printf '%s\n' "$FM_FSTYPE" ;; OPTIONS) printf '%s\n' "$FM_OPTIONS" ;; SOURCE) printf '%s\n' "$FM_SOURCE" ;; esac
}
mount() { record "mount $*"; mkdir -p "${*: -1}/@"; }
umount() { record "umount $*"; }
systemd-mount() { record "systemd-mount $*"; mkdir -p "${*: -1}/@"; }
systemd-umount() { record "systemd-umount $*"; }
btrfs() { record "btrfs $*"; }
fresh_target; CTX_DEFER_PROVISIONING=false
run_phase create_factory_snapshot
check 'phase ok' eq "$?" 0
top="$CTX_STATE_DIR/factory-top"
check 'top level mounted' contains "$(calls)" "systemd-mount --quiet -o subvolid=5 --property=PartOf=omarchy-install.target /dev/mapper/omarchy_root $top"
check 'snapshot taken' contains "$(calls)" "btrfs subvolume snapshot $top/@ $top/@factory"
check 'read-only' contains "$(calls)" "btrfs property set -ts $top/@factory ro true"
check 'unmounted' contains "$(calls)" "systemd-umount --quiet $top"

fresh_target; CTX_DEFER_PROVISIONING=false
factory="$CTX_STATE_DIR/factory-top/@factory"
for p in var/lib/omarchy/provisioning/authorized_keys etc/tailscale/authkey etc/omarchy/provisioning.key var/lib/omarchy/provisioning/groups; do
  mkdir -p "$factory/${p%/*}"; printf secret >"$factory/$p"
done
run_phase create_factory_snapshot
check 'scrubbed authorized_keys' test ! -e "$factory/var/lib/omarchy/provisioning/authorized_keys"
check 'scrubbed tailscale key' test ! -e "$factory/etc/tailscale/authkey"
check 'scrubbed provisioning key' test ! -e "$factory/etc/omarchy/provisioning.key"
check 'kept groups' test -e "$factory/var/lib/omarchy/provisioning/groups"

fresh_target; CTX_DEFER_PROVISIONING=false; FM_FSTYPE=ext4
run_phase create_factory_snapshot
check 'non-btrfs skips' test -z "$(calls | grep -E '^(systemd-)?mount' || true)"
FM_FSTYPE=btrfs FM_OPTIONS='rw,noatime'
fresh_target; CTX_DEFER_PROVISIONING=false
run_phase create_factory_snapshot
check 'non-subvol root skips' test -z "$(calls | grep -E '^(systemd-)?mount' || true)"

finish
