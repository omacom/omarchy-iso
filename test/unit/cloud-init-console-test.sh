#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CLOUD_CFG="$ROOT/configs/airootfs/etc/cloud/cloud.cfg.d/99-omarchy-installer-console.cfg"
SERVICES=(
  cloud-init-main.service
  cloud-init-local.service
  cloud-init-network.service
  cloud-config.service
  cloud-final.service
)

for service in "${SERVICES[@]}"; do
  drop_in="$ROOT/configs/airootfs/etc/systemd/system/$service.d/omarchy-console.conf"
  [[ -f $drop_in ]] || {
    echo "FAIL: $service has no Omarchy console drop-in" >&2
    exit 1
  }

  grep -qx 'StandardOutput=journal' "$drop_in" || {
    echo "FAIL: $service stdout is not confined to the journal" >&2
    exit 1
  }

  grep -qx 'StandardError=journal' "$drop_in" || {
    echo "FAIL: $service stderr is not confined to the journal" >&2
    exit 1
  }

  if grep -Eq '^Standard(Output|Error)=.*console' "$drop_in"; then
    echo "FAIL: $service output still names the installer console" >&2
    exit 1
  fi
done

[[ -f $CLOUD_CFG ]] || {
  echo "FAIL: cloud-init has no installer console configuration" >&2
  exit 1
}

grep -Eq '^no_ssh_fingerprints:[[:space:]]*true$' "$CLOUD_CFG" || {
  echo "FAIL: authorized-key fingerprints can still be written to the console" >&2
  exit 1
}

grep -Eq '^[[:space:]]+emit_keys_to_console:[[:space:]]*false$' "$CLOUD_CFG" || {
  echo "FAIL: SSH host keys can still be written directly to the console" >&2
  exit 1
}

echo "ok: cloud-init main and stage shims cannot write over the installer dashboard"
