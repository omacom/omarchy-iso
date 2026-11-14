#!/bin/bash
# What every account created on this machine starts with: /etc/skel is copied
# into the owner's home at first boot, and again after a factory reset.
set -euo pipefail

source /etc/acme-release
mkdir -p /etc/skel/Documents
printf 'Welcome to your %s.\nSupport: %s\n' "$MODEL" "$SUPPORT_URL" >/etc/skel/Documents/Welcome.txt
