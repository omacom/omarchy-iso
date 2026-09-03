#!/usr/bin/env bash
# configure_ssh_access: keys, sshd, ufw — against a temp target with
# arch-chroot recorded and the ufw side effect (writing user.rules) simulated.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

UFW_RULE='-A ufw-user-input -p tcp --dport 22 -j ACCEPT'
UFW_WRITES_RULE=true
arch-chroot() {
  record "arch-chroot $*"
  if [[ $2 == ufw ]]; then
    if [[ $UFW_WRITES_RULE == true ]]; then
      mkdir -p "$CTX_TARGET/etc/ufw"
      printf '%s\n' "$UFW_RULE" >"$CTX_TARGET/etc/ufw/user.rules"
    fi
    # ufw cannot reach netfilter inside a chroot and exits non-zero even when
    # it recorded the rule; the phase must not trust this.
    return 1
  fi
  return 0
}

setup() { # [authorized_keys content]
  fresh_target
  CTX_DEFER_PROVISIONING=false
  CTX_USERNAME=jeff
  UFW_WRITES_RULE=true
  if (($# > 0)); then
    printf '%s' "$1" >"$TMP/authorized_keys"
    CTX_AUTHORIZED_KEYS_PATH="$TMP/authorized_keys"
  fi
}
keys_file() { printf '%s' "$CTX_TARGET/home/jeff/.ssh/authorized_keys"; }
chrooted() { calls | grep "^arch-chroot $CTX_TARGET $1 " || true; }
# Not `! run_phase …`: a subshell negated with ! runs with errexit ignored,
# even when it sets -e itself, so fail() inside $(…) could not abort it.
fails_with() { run_phase configure_ssh_access; local rc=$?; ((rc != 0)) && contains "$(cat "$ERR")" "$1"; }

section 'no authorized keys is a no-op'
setup; run_phase configure_ssh_access
check 'no commands' eq "$(calls)" ''
check 'no .ssh' test ! -e "$CTX_TARGET/home/jeff/.ssh"

section 'installs keys one per line'
setup $'ssh-ed25519 AAAA jeff@host\nssh-rsa BBBB jeff@work\n'; run_phase configure_ssh_access
check 'file content' eq "$(cat "$(keys_file)")" $'ssh-ed25519 AAAA jeff@host\nssh-rsa BBBB jeff@work'
check 'trailing newline' eq "$(tail -c1 "$(keys_file)" | od -An -c | tr -d ' ')" '\n'

section 'drops blank lines and comments'
setup $'# work laptop\n\n  ssh-ed25519 AAAA jeff@host  \n'; run_phase configure_ssh_access
check 'only the key' eq "$(cat "$(keys_file)")" 'ssh-ed25519 AAAA jeff@host'

section 'keys with options pass through'
key='command="/usr/bin/true",no-pty ssh-ed25519 AAAA jeff@host'
setup "$key"$'\n'; run_phase configure_ssh_access
check 'verbatim' eq "$(cat "$(keys_file)")" "$key"

section 'permissions, chown, sshd, ufw'
setup $'ssh-ed25519 AAAA jeff@host\n'; run_phase configure_ssh_access
check 'phase ok' eq "$?" 0
check '.ssh is private' eq "$(mode_of "$CTX_TARGET/home/jeff/.ssh")" 700
check 'authorized_keys is private' eq "$(mode_of "$(keys_file)")" 600
check 'chown to user' eq "$(chrooted chown)" "arch-chroot $CTX_TARGET chown -R jeff:jeff /home/jeff/.ssh"
check 'sshd enabled' eq "$(chrooted systemctl)" "arch-chroot $CTX_TARGET systemctl enable sshd.service"
check 'ufw allow ssh despite chroot exit status' eq "$(chrooted ufw)" "arch-chroot $CTX_TARGET ufw allow ssh"

section 'fails when ufw does not record the rule'
setup $'ssh-ed25519 AAAA jeff@host\n'; UFW_WRITES_RULE=false
check 'error' fails_with 'allow rule for port 22'

section 'unusable key files fail the phase'
setup ''; check 'empty file' fails_with 'contains no SSH keys'
setup $'\n   \n'; check 'blank-only file' fails_with 'contains no SSH keys'
setup $'# no keys here\n'; check 'comment-only file' fails_with 'contains no SSH keys'

finish
