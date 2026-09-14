#!/bin/bash
#
# The udev rules shipped in the live ISO must parse: udevadm verify is a
# real parser, so a malformed rule fails here instead of silently never
# matching on the live system.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
rules_dir="$ROOT/configs/airootfs/etc/udev/rules.d"

if ! command -v udevadm >/dev/null || ! udevadm verify --help >/dev/null 2>&1; then
  echo "skip: udevadm verify unavailable"
  exit 0
fi

udevadm verify --no-style "$rules_dir"/*.rules

echo "ok: udev rules parse"
