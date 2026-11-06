#!/usr/bin/env bash
# The base install's custom_commands ran inside the installed system, with the
# cidata drive's files at $CIDATA, and the drive is not left in the installed
# system afterwards: it holds the credentials file.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

# What build_cidata's custom command puts in place; change them together.
PAYLOAD_PATH=/var/lib/omarchy-integration/custom-command-payload
PAYLOAD="ran from the cidata drive"

verify_custom_commands() {
  local payload
  # A base reused from before this scenario was installed without the command.
  if ! grep -q custom-command-payload "$BASE_CONFIG" 2>/dev/null; then
    log "Note: the base image was installed without the custom command; rebuild it without --reuse-base"
    return
  fi
  log "Booting the installed base image to check its custom command ran"
  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"
  payload=$(ssh_guest "cat $PAYLOAD_PATH" 2>/dev/null)
  if [[ -z $payload && $RELEASE_ISO == true ]]; then
    # A released ISO from before custom_commands ignores the field: noted, not failed.
    log "Note: this release ISO does not run custom_commands"
  else
    check "the custom command copied its file from the cidata drive" test "$payload" = "$PAYLOAD"
    check "the cidata drive is not left in the installed system" ssh_sudo "test ! -e /root/cidata"
  fi
  capture_console "success-custom-commands"
  stop_vm
}

verify_custom_commands
finish
