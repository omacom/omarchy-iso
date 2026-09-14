#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=${OMARCHY_SAFE_GRAPHICS_TEST_ROOT:-$ROOT}

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
    /^[[:space:]]*menuentry[[:space:]]/ && index($0, id) { inside = 1 }
    inside { print }
    inside && /^[[:space:]]*}/ { exit }
  ' "$config"
}

syslinux_entry() {
  local config="$1" label="$2"

  awk -v label="LABEL $label" '
    $0 == label { inside = 1 }
    inside && /^LABEL / && $0 != label { exit }
    /^TEXT HELP$/ { help = 1 }
    inside && !help { print }
    /^ENDTEXT$/ { help = 0 }
  ' "$config"
}

grub_setting() {
  awk -v key="$2" '
    $0 ~ "^[[:space:]]*(set[[:space:]]+)?" key "=" {
      value=$0
      sub("^[[:space:]]*(set[[:space:]]+)?" key "=", "", value)
      sub(/[[:space:]]*#.*$/, "", value)
      gsub(/^[[:space:]\047\042]+|[[:space:]\047\042]+$/, "", value)
    }
    END { print value }
  ' "$1"
}

kernel_line() {
  awk -v command="$1" '$1 == command && NF > 1 { print }'
}

for config in "$ROOT/configs/grub/grub.cfg" "$ROOT/configs/grub/loopback.cfg"; do
  normal=$(grub_entry "$config" archlinux)
  safe=$(grub_entry "$config" archlinux-safe-graphics)
  ids=$(sed -n "/^[[:space:]]*menuentry[[:space:]]/s/.*--id '\([^']*\)'.*/\1/p" "$config")

  [[ -n $normal ]] || fail "$(basename "$config") keeps the normal boot entry"
  normal_linux=$(kernel_line linux <<< "$normal")
  safe_linux=$(kernel_line linux <<< "$safe")
  [[ -n $normal_linux && -n $(kernel_line initrd <<< "$normal") ]] || fail "$(basename "$config") has a bootable normal entry"
  [[ -n $safe_linux && -n $(kernel_line initrd <<< "$safe") ]] || fail "$(basename "$config") has a bootable safe entry"
  [[ ! $normal_linux =~ (^|[[:space:]])nomodeset([[:space:]]|$) ]] || fail "$(basename "$config") leaves normal boot graphics unchanged"
  [[ $safe_linux =~ (^|[[:space:]])nomodeset([[:space:]]|$) ]] || fail "$(basename "$config") gives safe graphics its own kernel mode"
  # The hotkey is the only way in when gfxterm never paints the menu.
  [[ $(head -1 <<< "$safe") =~ (^|[[:space:]])--hotkey[[:space:]]+g([[:space:]]|$) ]] ||
    fail "$(basename "$config") gives safe graphics a hotkey"
  [[ $(wc -l <<<"$ids") == $(sort -u <<<"$ids" | wc -l) ]] ||
    fail "$(basename "$config") gives every menu entry a unique ID"
  [[ $(grep -ow 'nomodeset' "$config" | wc -l) == 1 ]] ||
    fail "$(basename "$config") limits nomodeset to safe graphics"
  [[ $(grub_setting "$config" default) == "archlinux" ]] || fail "$(basename "$config") keeps normal boot as the default"
  timeout=$(grub_setting "$config" timeout)
  [[ $timeout =~ ^[0-9]+$ ]] && (( 10#$timeout > 0 )) || fail "$(basename "$config") leaves time to select safe graphics"
  style=$(grub_setting "$config" timeout_style)
  [[ $style == "menu" || $style == "hidden" || $style == "countdown" ]] || fail "$(basename "$config") has a supported timeout style"

  pass "$(basename "$config") offers safe graphics without changing the default"
done

syslinux="$ROOT/configs/syslinux/archiso_sys-linux.cfg"
normal=$(syslinux_entry "$syslinux" arch64)
safe=$(syslinux_entry "$syslinux" arch64safe)

[[ -n $normal ]] || fail "Syslinux keeps the normal boot entry"
for entry in "$normal" "$safe"; do
  for directive in LINUX INITRD APPEND; do
    [[ -n $(kernel_line "$directive" <<< "$entry") ]] || fail "Syslinux boot entries require $directive"
  done
done
normal_append=$(kernel_line APPEND <<< "$normal")
safe_append=$(kernel_line APPEND <<< "$safe")
[[ ! $normal_append =~ (^|[[:space:]])nomodeset([[:space:]]|$) ]] || fail "Syslinux leaves normal boot graphics unchanged"
[[ $safe_append =~ (^|[[:space:]])nomodeset([[:space:]]|$) ]] || fail "Syslinux safe graphics disables kernel mode setting"
[[ $(grep -c '^LABEL arch64safe$' "$syslinux") == 1 ]] || fail "Syslinux has one safe graphics entry"
[[ $(awk '$1 == "DEFAULT" { value=$2 } END { print value }' "$ROOT/configs/syslinux/archiso_sys.cfg") == "arch64" ]] || fail "Syslinux keeps normal boot as the default"
pass "Syslinux offers safe graphics without changing the default"
