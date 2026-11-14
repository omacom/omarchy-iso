#!/bin/bash

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A harness that only asserts failure goes green when the fixture itself is
# broken, so prove an untouched copy still passes before trusting a rejection.
baseline="$test_tmp/baseline"
mkdir -p "$baseline"
cp -r "$ROOT/configs" "$baseline/"
if ! OMARCHY_SAFE_GRAPHICS_TEST_ROOT="$baseline" bash "$ROOT/test/unit/safe-graphics-boot-test.sh" > "$baseline/output" 2>&1; then
  cat "$baseline/output" >&2
  printf 'not ok - safe graphics tests accept an unmutated tree\n' >&2
  exit 1
fi
printf 'ok - safe graphics tests accept an unmutated tree\n'

for mutation in comment_only help_only bios_default zero_timeout grub_default missing_initrd no_hotkey; do
  fixture="$test_tmp/$mutation"
  mkdir -p "$fixture"
  cp -r "$ROOT/configs" "$fixture/"
  grub="$fixture/configs/grub/grub.cfg"
  syslinux="$fixture/configs/syslinux/archiso_sys-linux.cfg"
  case "$mutation" in
  comment_only)
    sed -i "/^menuentry .*--id 'archlinux-safe-graphics'/,/^}/d" "$grub"
    printf '%s\n' "# --id 'archlinux-safe-graphics' nomodeset" >> "$grub"
    ;;
  help_only)
    sed -i '/^LABEL arch64safe$/,/^LABEL arch64speech$/ { /^LINUX /d; /^INITRD /d; /^APPEND /d; }' "$syslinux"
    sed -i '/^TEXT HELP$/a nomodeset' "$syslinux"
    ;;
  bios_default)
    printf '%s\n' 'DEFAULT arch64safe' >> "$fixture/configs/syslinux/archiso_sys.cfg"
    ;;
  zero_timeout)
    printf '%s\n' 'timeout=0' 'timeout_style=hidden' >> "$grub"
    ;;
  grub_default)
    printf '%s\n' 'set default=archlinux-safe-graphics' >> "$grub"
    ;;
  missing_initrd)
    sed -i "/^menuentry .*--id 'archlinux-safe-graphics'/,/^}/ { /^[[:space:]]*initrd /d; }" "$grub"
    ;;
  no_hotkey)
    sed -i "/--id 'archlinux-safe-graphics'/s/ --hotkey g//" "$grub"
    ;;
  esac
  if OMARCHY_SAFE_GRAPHICS_TEST_ROOT="$fixture" bash "$ROOT/test/unit/safe-graphics-boot-test.sh" > "$fixture/output" 2>&1; then
    printf 'not ok - safe graphics tests accepted %s\n' "$mutation" >&2
    exit 1
  fi
  printf 'ok - safe graphics tests reject %s\n' "$mutation"
done
