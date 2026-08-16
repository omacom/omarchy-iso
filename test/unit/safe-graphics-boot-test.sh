#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

grub_entry() {
  local config="$1" id="$2"

  awk -v id="--id '$id'" '
    index($0, id) { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$config"
}

syslinux_entry() {
  local config="$1" label="$2"

  awk -v label="LABEL $label" '
    $0 == label { inside = 1 }
    inside && /^LABEL / && $0 != label { exit }
    inside { print }
  ' "$config"
}

for config in "$ROOT/configs/grub/grub.cfg" "$ROOT/configs/grub/loopback.cfg"; do
  normal=$(grub_entry "$config" archlinux)
  safe=$(grub_entry "$config" archlinux-safe-graphics)
  ids=$(sed -n "s/.*--id '\([^']*\)'.*/\1/p" "$config")

  [[ -n $normal ]] || fail "$(basename "$config") keeps the normal boot entry"
  [[ $normal != *nomodeset* ]] || fail "$(basename "$config") leaves normal boot graphics unchanged"
  [[ $safe == *nomodeset* ]] || fail "$(basename "$config") gives safe graphics its own kernel mode"
  [[ $(wc -l <<<"$ids") == $(sort -u <<<"$ids" | wc -l) ]] ||
    fail "$(basename "$config") gives every menu entry a unique ID"
  [[ $(grep -ow 'nomodeset' "$config" | wc -l) == 1 ]] ||
    fail "$(basename "$config") limits nomodeset to safe graphics"
  grep -Fxq 'default=archlinux' "$config" || fail "$(basename "$config") keeps normal boot as the default"
  grep -Fxq 'timeout=3' "$config" || fail "$(basename "$config") leaves time to select safe graphics"
  grep -Fxq 'timeout_style=menu' "$config" || fail "$(basename "$config") shows the safe graphics choice"

  pass "$(basename "$config") offers safe graphics without changing the default"
done

syslinux="$ROOT/configs/syslinux/archiso_sys-linux.cfg"
normal=$(syslinux_entry "$syslinux" arch64)
safe=$(syslinux_entry "$syslinux" arch64safe)

[[ -n $normal ]] || fail "Syslinux keeps the normal boot entry"
[[ $normal != *nomodeset* ]] || fail "Syslinux leaves normal boot graphics unchanged"
[[ $safe == *nomodeset* ]] || fail "Syslinux safe graphics disables kernel mode setting"
[[ $(grep -c '^LABEL arch64safe$' "$syslinux") == 1 ]] || fail "Syslinux has one safe graphics entry"
pass "Syslinux offers safe graphics without changing the default"
