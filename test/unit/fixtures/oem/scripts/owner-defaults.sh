#!/bin/bash
# What every account created on this machine starts with: /etc/skel is copied
# into the owner's home at first boot, and again after a factory reset.
set -euo pipefail

# shellcheck source=/dev/null # support-info.sh writes it on the target first
source /etc/acme-release
mkdir -p /etc/skel/Documents
# shellcheck disable=SC2154 # both come from /etc/acme-release
printf 'Welcome to your %s.\nSupport: %s\n' "$MODEL" "$SUPPORT_URL" >/etc/skel/Documents/Welcome.txt
