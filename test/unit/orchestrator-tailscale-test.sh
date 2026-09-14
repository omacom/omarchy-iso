#!/usr/bin/env bash
# configure_tailscale: key staging, the first-boot join unit, services, ufw.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

UFW_RULE='-A ufw-user-input -i tailscale0 -j ACCEPT'
UFW_WRITES_RULE=true
arch-chroot() {
  record "arch-chroot $*"
  if [[ $2 == ufw ]]; then
    if [[ $UFW_WRITES_RULE == true ]]; then
      mkdir -p "$CTX_TARGET/etc/ufw"
      printf '%s\n' "$UFW_RULE" >"$CTX_TARGET/etc/ufw/user.rules"
    fi
    return 1
  fi
  return 0
}

setup() { # [authkey content] [tailscale_installed true|false]
  fresh_target
  UFW_WRITES_RULE=true
  if (($# > 0)); then
    printf '%s' "$1" >"$TMP/tailscale_authkey"
    CTX_TAILSCALE_AUTHKEY_PATH="$TMP/tailscale_authkey"
  fi
  if [[ ${2:-true} == true ]]; then
    mkdir -p "$CTX_TARGET/usr/bin"
    touch "$CTX_TARGET/usr/bin/tailscale"
  fi
}
staged_key() { printf '%s' "$CTX_TARGET/etc/tailscale/authkey"; }
unit() { printf '%s' "$CTX_TARGET/etc/systemd/system/omarchy-tailscale-join.service"; }
chrooted() { calls | grep "^arch-chroot $CTX_TARGET $1 " || true; }
# Not `! run_phase …`: a subshell negated with ! runs with errexit ignored,
# even when it sets -e itself, so fail() inside $(…) could not abort it.
fails_with() { run_phase configure_tailscale; local rc=$?; ((rc != 0)) && contains "$(cat "$ERR")" "$1"; }

section 'no auth key is a no-op'
setup; run_phase configure_tailscale
check 'no commands' eq "$(calls)" ''
check 'no /etc/tailscale' test ! -e "$CTX_TARGET/etc/tailscale"

section 'stages the key'
setup $'tskey-auth-kFAKEKEY\n'; run_phase configure_tailscale
check 'phase ok' eq "$?" 0
check 'key with newline' eq "$(cat "$(staged_key)"; printf x)" $'tskey-auth-kFAKEKEY\nx'
check 'dir private' eq "$(mode_of "$CTX_TARGET/etc/tailscale")" 700
check 'file private' eq "$(mode_of "$(staged_key)")" 600

section 'drops blank lines and comments'
setup $'# reusable, tagged\n\n  tskey-auth-kFAKEKEY  \n'; run_phase configure_tailscale
check 'only the key' eq "$(cat "$(staged_key)")" tskey-auth-kFAKEKEY

section 'the join unit'
setup $'tskey-auth-kFAKEKEY\n'; run_phase configure_tailscale
text=$(cat "$(unit)")
check 'condition on the key' contains "$text" 'ConditionPathExists=/etc/tailscale/authkey'
check 'join, cleanup and disable sequenced in the script' contains "$text" \
  "ExecStart=/usr/bin/sh -c 'until tailscale up --auth-key file:/etc/tailscale/authkey; do sleep 15; done; rm -f /etc/tailscale/authkey; systemctl disable omarchy-tailscale-join.service'"
check 'Type=simple' contains "$text" 'Type=simple'
check 'not oneshot' test "${text/Type=oneshot/}" == "$text"
check 'no start timeout' test "${text/TimeoutStartSec/}" == "$text"
check 'no $ for systemd to expand' test "${text/\$/}" == "$text"
check 'services enabled' eq "$(chrooted systemctl)" "arch-chroot $CTX_TARGET systemctl enable tailscaled.service omarchy-tailscale-join.service"
check 'ufw allow despite chroot exit status' eq "$(chrooted ufw)" "arch-chroot $CTX_TARGET ufw allow in on tailscale0"

section 'failure modes'
setup $'tskey-auth-kFAKEKEY\n'; UFW_WRITES_RULE=false
check 'ufw rule not recorded' fails_with 'allow rule for tailscale0'
setup $'tskey-auth-kFAKEKEY\n' false
check 'tailscale not on the target' fails_with 'not installed on the target'
setup ''; check 'empty file' fails_with 'contains no auth key'
setup $'# no key here\n'; check 'comment-only file' fails_with 'contains no auth key'
setup $'tskey-auth-kONE\ntskey-auth-kTWO\n'; check 'multiple keys' fails_with 'expected exactly one'

finish
