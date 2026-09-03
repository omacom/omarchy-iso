# shellcheck shell=bash
# Provisioning state, login, SSH, Tailscale, DNS and the factory snapshot.

# ─────────────────────────────────────────────────────────────────────────────
# stage_provisioning_state: produce the on-disk "provisioning state" the
# runtime's first-boot setup (omarchy-provision-owner) and factory reset
# (omarchy-system-factory-reset) consume.
#
# Every install stashes the bundled Node tarball in
# /var/lib/omarchy/provisioning/ so a later factory reset can finalize the new
# owner's user offline. Deferred-provisioning installs additionally arm the
# first-boot setup service and, on encrypted targets, stage the throwaway LUKS
# passphrase: the keyfile embedded in the initramfs auto-unlocks boot during
# the provisioning window, and first-boot setup re-keys the volume to the
# owner's password and removes it.
#
# Runs before finalize_limine_boot so the cryptkey cmdline drop-in and the
# keyfile land in the final UKI build.
# ─────────────────────────────────────────────────────────────────────────────

PROVISION_STATE_DIR=var/lib/omarchy/provisioning
PROVISION_KEYFILE=etc/omarchy/provisioning.key
NODE_PACKAGES_DIR=${NODE_PACKAGES_DIR:-/opt/packages}

stage_provisioning_state() {
  # World-readable: first-boot finalization reads the Node tarball as the
  # new user. The only secret inside (luks-key) is itself 0600 root.
  local provisioning_dir="$CTX_TARGET/$PROVISION_STATE_DIR"
  mkdir -p "$provisioning_dir"
  chmod 0755 "$provisioning_dir"

  stage_node_tarball "$provisioning_dir"

  [[ $CTX_DEFER_PROVISIONING == true ]] || return 0

  local service_src="$CTX_TARGET/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  if [[ ! -e $service_src || ! -e $CTX_TARGET/usr/bin/omarchy-provision-owner ]]; then
    fail 'deferred-provisioning install requested, but the installed Omarchy runtime does not ship first-boot setup (omarchy-provision-owner + install/provisioning/omarchy-provision-owner.service). Update the runtime package this ISO bundles before installing in deferred provisioning.'
  fi

  info '› arming first-boot setup'
  touch "$provisioning_dir/pending"

  mkdir -p "$CTX_TARGET/etc/systemd/system/multi-user.target.wants"
  cp -p "$service_src" "$CTX_TARGET/etc/systemd/system/omarchy-provision-owner.service"
  ln -sfn /etc/systemd/system/omarchy-provision-owner.service \
    "$CTX_TARGET/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"

  if provision_install_encrypted; then
    stage_provisioning_luks_unlock "$provisioning_dir"
  fi
}

stage_node_tarball() {
  local provisioning_dir=$1 tarball=''
  local -a tarballs=()
  for tarball in "$NODE_PACKAGES_DIR"/node-v*-linux-x64.tar.gz; do
    [[ -f $tarball ]] && tarballs+=("$tarball")
  done
  # Hard error on every install, not just deferred-provisioning installs: the
  # stash is what lets a later factory reset finalize the next owner offline,
  # and an ISO build always bundles the tarball — its absence means a broken
  # build.
  ((${#tarballs[@]})) || fail "no bundled Node tarball in $NODE_PACKAGES_DIR — first-boot setup and factory reset could not finalize a user offline"

  local packages_dir="$provisioning_dir/packages"
  mkdir -p "$packages_dir"
  if [[ ! -e $packages_dir/${tarballs[0]##*/} ]]; then
    info '› stashing Node tarball for offline first-boot setup'
    cp -p "${tarballs[0]}" "$packages_dir/${tarballs[0]##*/}"
  fi
}

provision_install_encrypted() {
  [[ -n $(storage_intent luks_uuid) ]] && return 0
  local enc_type
  enc_type=$(user_configuration_get '.disk_config.disk_encryption | if type == "object" then (.encryption_type // "luks") else empty end')
  [[ -n $enc_type && $enc_type != no_encryption ]] && return 0
  [[ $CTX_ENCRYPT == true ]]
}

provision_encryption_password() {
  local password
  password=$(user_configuration_get '.disk_config.disk_encryption.encryption_password')
  [[ -n $password ]] || password=$(jq -r '.encryption_password // empty' <<<"$CTX_USER_CREDENTIALS")
  printf '%s' "$password"
}

stage_provisioning_luks_unlock() {
  local provisioning_dir=$1 password
  password=$(provision_encryption_password)
  # Full-disk deferred-provisioning installs get a generated passphrase
  # injected by the context; only a pre-mounted (rig-partitioned) LUKS target
  # can land here, and it must hand over the passphrase it formatted with.
  [[ -n $password ]] || fail 'deferred-provisioning install on a pre-encrypted target requires the LUKS passphrase in user_credentials.json (encryption_password) so first boot can re-key'

  info '› staging LUKS auto-unlock for the provisioning window'

  # Byte-for-byte the slot passphrase: no trailing newline anywhere.
  (umask 077 && printf '%s' "$password" >"$provisioning_dir/luks-key")
  chmod 0600 "$provisioning_dir/luks-key"

  local keyfile="$CTX_TARGET/$PROVISION_KEYFILE"
  mkdir -p "${keyfile%/*}"
  (umask 077 && printf '%s' "$password" >"$keyfile")
  chmod 0600 "$keyfile"

  mkdir -p "$CTX_TARGET/etc/limine-entry-tool.d" "$CTX_TARGET/etc/mkinitcpio.conf.d"
  printf 'KERNEL_CMDLINE[default]+=" cryptkey=rootfs:/etc/omarchy/provisioning.key"\n' \
    >"$CTX_TARGET/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf"
  printf 'FILES+=(/etc/omarchy/provisioning.key)\n' >"$CTX_TARGET/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
}

# Put the installed system in systemd-resolved stub mode.
#
# Arch's systemd-resolved docs explicitly say not to create this symlink from
# inside arch-chroot because /etc/resolv.conf may be a bind mount from the
# live environment. Do it from the ISO against the target instead.
configure_dns_resolver() {
  local resolv_conf="$CTX_TARGET/etc/resolv.conf" target=../run/systemd/resolve/stub-resolv.conf
  [[ -L $resolv_conf && $(readlink "$resolv_conf") == "$target" ]] && return 0

  info '› configuring /etc/resolv.conf for systemd-resolved'
  mkdir -p "${resolv_conf%/*}"
  rm -f "$resolv_conf"
  ln -s "$target" "$resolv_conf"
}

# ─────────────────────────────────────────────────────────────────────────────
# configure_login: seed SDDM's last user/session for the password-only Omarchy
# greeter. Encrypted installs autologin because the LUKS prompt is the auth
# boundary; unencrypted installs leave SDDM as the auth screen.
# ─────────────────────────────────────────────────────────────────────────────

configure_login() {
  local sddm_dir="$CTX_TARGET/etc/sddm.conf.d"
  mkdir -p "$sddm_dir"
  printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' >"$sddm_dir/99-omarchy-login.conf"

  if [[ $CTX_ENCRYPT == true && $CTX_DEFER_PROVISIONING != true ]]; then
    printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$CTX_USERNAME" >"$sddm_dir/autologin.conf"
  else
    # Deferred-provisioning installs have no user yet; omarchy-provision-owner
    # writes autologin and SDDM state at first boot once the owner exists.
    rm -f "$sddm_dir/autologin.conf"
  fi

  if [[ $CTX_DEFER_PROVISIONING != true ]]; then
    mkdir -p "$CTX_TARGET/var/lib/sddm"
    printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$CTX_USERNAME" >"$CTX_TARGET/var/lib/sddm/state.conf"
    arch-chroot "$CTX_TARGET" chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf >/dev/null 2>&1 || true
  fi

  rm -f "$CTX_TARGET/etc/systemd/system/getty@tty1.service.d/autologin.conf"

  arch-chroot "$CTX_TARGET" systemctl enable sddm.service >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# configure_ssh_access: make the installed machine reachable over SSH with the
# keys an autoinstall drive supplied. A stock Omarchy install ships openssh but
# leaves sshd disabled, and its firewall.sh opens only LocalSend and docker DNS,
# so all three pieces -- keys, service, firewall -- have to be done here.
# ─────────────────────────────────────────────────────────────────────────────

configure_ssh_access() {
  [[ -n $CTX_AUTHORIZED_KEYS_PATH ]] || return 0

  local keys count
  keys=$(authorized_keys "$CTX_AUTHORIZED_KEYS_PATH")
  count=$(wc -l <<<"$keys")

  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    # No user to authorize yet. Stage the keys in provisioning state for
    # omarchy-provision-owner to install once first boot creates the owner,
    # and still open the door (sshd + ufw) below.
    info "› staging $count SSH key(s) for the first-boot user"
    local provisioning_dir="$CTX_TARGET/$PROVISION_STATE_DIR"
    mkdir -p "$provisioning_dir"
    (umask 077 && printf '%s\n' "$keys" >"$provisioning_dir/authorized_keys")
    chmod 0600 "$provisioning_dir/authorized_keys"
  else
    info "› installing $count SSH key(s) for $CTX_USERNAME"
    local ssh_dir="$CTX_TARGET/home/$CTX_USERNAME/.ssh"
    mkdir -p "$ssh_dir"
    chmod 0700 "$ssh_dir"
    (umask 077 && printf '%s\n' "$keys" >"$ssh_dir/authorized_keys")
    chmod 0600 "$ssh_dir/authorized_keys"

    # Ask the target for the uid rather than assuming the first user is 1000.
    # Uncaptured so a failure shows up in the install log, and checked because
    # a root-owned authorized_keys is one sshd refuses to read.
    arch-chroot "$CTX_TARGET" chown -R "$CTX_USERNAME:$CTX_USERNAME" "/home/$CTX_USERNAME/.ssh"
  fi

  info '› enabling sshd'
  arch-chroot "$CTX_TARGET" systemctl enable sshd.service

  # Open port 22 in the target's ufw, which runs default-deny incoming, so an
  # enabled sshd is still unreachable -- connections time out rather than
  # being refused.
  #
  # ufw cannot reach netfilter from inside the chroot and exits non-zero
  # saying so, but it writes the rule to user.rules first, and that file is
  # what ufw.service loads on first boot. So the exit status is the wrong
  # thing to check here; the rule landing in the file is the thing that
  # matters.
  info '› allowing SSH through ufw'
  arch-chroot "$CTX_TARGET" ufw allow ssh || true

  local rules="$CTX_TARGET/etc/ufw/user.rules"
  grep -qF -- '--dport 22 -j ACCEPT' "$rules" 2>/dev/null || fail "ufw did not record an allow rule for port 22 in $rules"
}

# Read the autoinstall authorized_keys: sshd's own format, one public key per
# line, with blank lines and # comments dropped.
#
# Fail rather than skip on anything unusable. An install that "succeeds" into
# a machine nobody can log into is worse than one that stops with the reason
# on screen.
authorized_keys() {
  local path=$1 keys
  [[ -r $path ]] || fail "$path is not readable"
  keys=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$path")
  [[ -n $keys ]] || fail "$path contains no SSH keys"
  printf '%s' "$keys"
}

# ─────────────────────────────────────────────────────────────────────────────
# configure_tailscale: stage the tailnet join an autoinstall drive asked for.
# `tailscale up` needs a running tailscaled and there is no systemd in the
# chroot, so the install only stages: the key, the enabled services, and a
# first-boot unit that performs the join once the network is really there.
# The package itself was installed from the offline mirror during
# install_system_payload -- nothing is fetched at boot.
# ─────────────────────────────────────────────────────────────────────────────

TAILSCALE_AUTHKEY_TARGET=/etc/tailscale/authkey

# systemd expands $VAR in ExecStart, so the retry loop avoids `$` entirely.
# network-online.target can be reached before there is real connectivity, so
# retry inside the boot -- but NOT as a oneshot: target units implicitly gain
# After= for their Wants=, so a oneshot in multi-user.target holds the whole
# boot (SDDM included) hostage until it finishes. Type=simple counts as
# started the moment it forks, letting boot proceed while the join retries in
# the background for as long as the boot lasts. Cleanup lives inside the
# script because it must only run after a successful join: the key is removed
# and the unit disabled on success, while on a boot with no connectivity both
# survive -- so a machine installed offline joins on the first boot that can.
tailscale_join_unit() {
  cat <<UNIT
[Unit]
Description=Join the tailnet with the auth key staged by autoinstall
Wants=network-online.target
After=network-online.target tailscaled.service
Requires=tailscaled.service
ConditionPathExists=$TAILSCALE_AUTHKEY_TARGET

[Service]
Type=simple
ExecStart=/usr/bin/sh -c 'until tailscale up --auth-key file:$TAILSCALE_AUTHKEY_TARGET; do sleep 15; done; rm -f $TAILSCALE_AUTHKEY_TARGET; systemctl disable omarchy-tailscale-join.service'

[Install]
WantedBy=multi-user.target
UNIT
}

configure_tailscale() {
  [[ -n $CTX_TAILSCALE_AUTHKEY_PATH ]] || return 0

  local key
  key=$(tailscale_authkey "$CTX_TAILSCALE_AUTHKEY_PATH")

  # An ISO built before tailscale was bundled installs nothing, and a staged
  # key with no binary would fail silently forever on first boot.
  [[ -e $CTX_TARGET/usr/bin/tailscale ]] || fail 'tailscale is not installed on the target; this ISO does not bundle it'

  info '› staging Tailscale auth key'
  local ts_dir="$CTX_TARGET/etc/tailscale"
  mkdir -p "$ts_dir"
  chmod 0700 "$ts_dir"
  (umask 077 && printf '%s\n' "$key" >"$ts_dir/authkey")
  chmod 0600 "$ts_dir/authkey"

  info '› enabling tailscaled and the first-boot join'
  mkdir -p "$CTX_TARGET/etc/systemd/system"
  tailscale_join_unit >"$CTX_TARGET/etc/systemd/system/omarchy-tailscale-join.service"
  arch-chroot "$CTX_TARGET" systemctl enable tailscaled.service omarchy-tailscale-join.service

  # Same dance as configure_ssh_access: ufw cannot reach netfilter from the
  # chroot and exits non-zero, but it records the rule in user.rules first,
  # and that file is what ufw.service loads on first boot. Without the rule
  # the node joins the tailnet and is then unreachable over it.
  info '› allowing tailnet traffic through ufw'
  arch-chroot "$CTX_TARGET" ufw allow in on tailscale0 || true

  local rules="$CTX_TARGET/etc/ufw/user.rules"
  grep -qF -- '-i tailscale0 -j ACCEPT' "$rules" 2>/dev/null || fail "ufw did not record an allow rule for tailscale0 in $rules"
}

# Read the autoinstall tailscale_authkey: exactly one key, with blank lines
# and # comments dropped. No format validation beyond that -- key formats are
# Tailscale's to change. Fail rather than skip on anything unusable, same
# reasoning as authorized_keys.
tailscale_authkey() {
  local path=$1 keys n
  [[ -r $path ]] || fail "$path is not readable"
  keys=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$path")
  [[ -n $keys ]] || fail "$path contains no auth key"
  n=$(wc -l <<<"$keys")
  ((n == 1)) || fail "$path contains $n keys; expected exactly one"
  printf '%s' "$keys"
}

# ─────────────────────────────────────────────────────────────────────────────
# create_factory_snapshot: read-only snapshot of @ kept at the btrfs top level
# as @factory — outside snapper's .snapshots, so cleanup timers and the Limine
# snapshot menu never touch it. Zero bytes at creation; grows only with drift.
# Taken at the end of every install, it is what makes
# omarchy-system-factory-reset a true factory reset.
# ─────────────────────────────────────────────────────────────────────────────

create_factory_snapshot() {
  local fstype options device
  fstype=$(findmnt_value "$CTX_TARGET" FSTYPE)
  if [[ $fstype != btrfs ]]; then
    info "› target root is ${fstype:-unknown}, not btrfs; skipping factory snapshot"
    return 0
  fi

  options=$(findmnt_value "$CTX_TARGET" OPTIONS)
  if ! list_contains "${options//,/ }" 'subvol=/@' && ! list_contains "${options//,/ }" 'subvol=@'; then
    info '› target root is not the @ subvolume; skipping factory snapshot'
    return 0
  fi

  device=$(findmnt_value "$CTX_TARGET" SOURCE)
  device=${device%%\[*}
  [[ -n $device ]] || fail "could not determine the btrfs device backing $CTX_TARGET"

  # The keyring unit writes into @; the snapshot must not catch it midway.
  join_target_keyring_init

  local top="$CTX_STATE_DIR/factory-top"
  mkdir -p "$top"
  # A transient mount unit (the device is only known at run time): PartOf=
  # the install target means a mid-phase death unmounts it with the group
  # teardown, with no per-process trap bookkeeping.
  systemd-mount --quiet -o subvolid=5 --property=PartOf=omarchy-install.target \
    "$device" "$top" || fail "could not mount the target filesystem's top level at $top"
  factory_snapshot_in "$top"
  systemd-umount --quiet "$top" >/dev/null 2>&1 || true
}

factory_snapshot_in() {
  local top=$1 factory="$1/@factory"
  [[ -d $top/@ ]] || fail "no @ subvolume at the top level"
  if [[ -e $factory ]]; then
    btrfs subvolume delete "$factory" >/dev/null 2>&1 || fail "could not delete the previous @factory"
  fi

  info '› snapshotting @ as @factory (read-only)'
  btrfs subvolume snapshot "$top/@" "$factory"
  scrub_factory_snapshot "$factory"
  btrfs property set -ts "$factory" ro true
}

# Provisioning credentials staged for THIS deployment's first boot must not
# survive into the factory image: a reset years later would otherwise hand the
# next owner the original deployment's SSH keys or rejoin its tailnet, and a
# stale LUKS key (dead after the first re-key) has no business lingering.
# The mkinitcpio/cmdline drop-ins go with the keyfile — a reset rebuild would
# otherwise fail on FILES pointing at a scrubbed path.
FACTORY_SCRUB_PATHS=(
  var/lib/omarchy/provisioning/authorized_keys
  var/lib/omarchy/provisioning/luks-key
  etc/omarchy/provisioning.key
  etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf
  etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf
  etc/tailscale/authkey
  etc/systemd/system/omarchy-tailscale-join.service
  etc/systemd/system/multi-user.target.wants/omarchy-tailscale-join.service
)

scrub_factory_snapshot() {
  local factory=$1 rel
  for rel in "${FACTORY_SCRUB_PATHS[@]}"; do
    rm -f "$factory/$rel"
  done
}

findmnt_value() {
  local value
  value=$(findmnt -no "$2" "$1" 2>/dev/null) || return 0
  printf '%s' "$value"
}
