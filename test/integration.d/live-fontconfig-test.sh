#!/usr/bin/env bash
# The live ISO must ship a valid prebuilt fontconfig cache for its own trimmed
# /usr/share/fonts tree so kmscon does not index desktop fonts at boot.
# Standalone: OMARCHY_INTEGRATION_ISO=/path/to.iso bash test/integration.d/live-fontconfig-test.sh

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
qemu-img create -f qcow2 "$RUN_DIR/scratch.qcow2" 1G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"

MEMORY=2048 start_vm "$RUN_DIR/scratch.qcow2" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
bootstrap_live_root_ssh

check "airootfs ships prebuilt fontconfig caches" \
  ssh_live_root 'find /run/archiso/airootfs/var/cache/fontconfig -maxdepth 1 -name "*.cache-*" -print -quit | grep -q .'
check "live /usr/share/fonts is opaque (desktop noto fonts stay out)" \
  ssh_live_root 'test ! -e /usr/share/fonts/noto'
check "fc-match resolves JetBrainsMono Nerd Font without rebuilding caches at runtime" \
  ssh_live_root 'bash -euo pipefail -s' <<'GUEST'
match=$(fc-match "JetBrainsMono Nerd Font")
grep -q "JetBrainsMono" <<<"$match" || { echo "unexpected match: $match" >&2; exit 1; }
upper=$(findmnt -no OPTIONS / | tr ',' '\n' | sed -n 's/^upperdir=//p')
test -n "$upper"
! compgen -G "$upper/var/cache/fontconfig/*.cache-*" >/dev/null
! compgen -G "/root/.cache/fontconfig/*.cache-*" >/dev/null
GUEST

stop_vm
finish
