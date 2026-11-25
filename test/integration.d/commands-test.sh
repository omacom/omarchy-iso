#!/usr/bin/env bash
# Every command in test/required-commands.txt exists on the installed system.
#
# The Ubuntu 26.04 minimal images lost curl and xxd because
# both were only ever present as dependencies of pollinate, and pollinate was
# dropped. Omarchy's scripts call commands from packages that no Omarchy
# package list names; this scenario is the contract that keeps them present,
# whatever the dependency graph does underneath.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

verify_required_commands() {
  local list="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/required-commands.txt" missing
  log "Booting the installed base image to check the command contract"
  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"
  check "installed system is reachable" ssh_guest "test ! -e /run/archiso"
  missing=$(grep -v '^#\|^$' "$list" | ssh_guest 'while read -r c; do command -v "$c" >/dev/null 2>&1 || echo "$c"; done' 2>/dev/null)
  check "every command in test/required-commands.txt exists on the installed system${missing:+ (missing: ${missing//$'\n'/ })}" \
    test -z "$missing"
  capture_console "success-commands"
  stop_vm
}

verify_required_commands
finish
