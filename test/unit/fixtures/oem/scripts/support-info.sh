#!/bin/bash
# Runs in the installed system during the factory install: what this machine
# shipped as, where support can read it.
set -euo pipefail

cat >/etc/acme-release <<RELEASE
MODEL="Acme Book 14"
BUILD="$(date -u +%Y.%m.%d)"
SUPPORT_URL="https://acme.example/support"
RELEASE
