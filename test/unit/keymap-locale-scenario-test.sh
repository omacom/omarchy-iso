#!/bin/bash
#
# The keymap-locale scenario's initramfs checks without a VM. The guest's
# /boot is a directory here, holding initramfs images (newc cpio archives),
# so which image the scenario reads on a UEFI install (the UKI) and on a
# BIOS install (the kernel-and-initramfs pair Limine loads), and what it
# concludes from it, can be checked here.

# shellcheck disable=SC2034,SC2329 # the variables and stubs are used by the functions taken out of the scenario

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scenario="$ROOT/test/integration.d/keymap-locale-test.sh"
harness="$ROOT/test/integration.d/base-test.sh"
bash -n "$scenario"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The scenario boots a VM when it is run: take its functions and the
# harness's check, not the lines that run them.
eval "$(sed -e '/^source /d' -e '/^base_image_ready /d' -e '/^verify_keymap_and_locale$/d' -e '/^finish$/d' "$scenario")"
eval "$(sed -n '/^check() {$/,/^}$/p' "$harness")"
declare -F verify_keymap_and_locale check >/dev/null || fail "the scenario or the harness changed shape"

log() { :; }
vm_running() { false; }
capture_console() { :; }
start_vm_from_base() { :; }
wait_for_ssh() { :; }
stop_vm() { :; }
ssh_guest() { true; } # the installed target's files; not what is tested here
ssh_sudo() { PATH="$work/bin:$PATH" bash -c "${1//\/boot\//$work/root/boot/}"; }
# lsinitcpio's -l and -x on a plain cpio, which is all the images here are.
mkdir -p "$work/bin"
cat >"$work/bin/lsinitcpio" <<'SH'
#!/bin/sh
case $1 in
  -l) exec bsdtar -tf "$2" ;;
  -x) exec bsdtar -xf "$3" ;;
esac
exit 2
SH
chmod +x "$work/bin/lsinitcpio"

# An initramfs with a compiled keymap and the vconsole.conf it came from.
initramfs() { # path keymap
  local tree="$work/tree"
  rm -rf "$tree"
  mkdir -p "$tree/etc" "$(dirname "$1")"
  echo '#!/bin/sh' >"$tree/init"
  echo keymap >"$tree/keymap.bin"
  echo "KEYMAP=$2" >"$tree/etc/vconsole.conf"
  bsdtar --format newc -cf "$1" -C "$tree" init keymap.bin etc
}

# limine-entry-tool's entry for a BIOS install: a kernel and its initramfs,
# then the snapshot entries.
bios_boot() { # keymap
  rm -rf "$work/root"
  initramfs "$work/root/boot/f00d/linux-omarchy/initramfs-linux-omarchy" "$1"
  initramfs "$work/root/boot/f00d/limine_history/initramfs-linux-omarchy" us
  cat >"$work/root/boot/limine.conf" <<'EOF'
/+Omarchy
comment: Omarchy
  //linux-omarchy
  comment: kernel-id=linux-omarchy
  protocol: linux
  path: boot():/f00d/linux-omarchy/vmlinuz-linux-omarchy#abcd
  module_path: boot():/f00d/linux-omarchy/initramfs-linux-omarchy#abcd
  cmdline: root=UUID=test rw
     //Snapshots
     ///1 | 2026-10-01 00:00:00
     ////linux-omarchy
     protocol: linux
     path: boot():/f00d/limine_history/vmlinuz-linux-omarchy#abcd
     module_path: boot():/f00d/limine_history/initramfs-linux-omarchy#abcd
     cmdline: root=UUID=test rw rootflags=subvol=/@/.snapshots/1/snapshot
EOF
}

verify() { # firmware: run the scenario's checks, the failures into $FAILURES
  FIRMWARE=$1 KB_LAYOUT=uk FAILURES=0 BOOT_TIMEOUT=600
  verify_keymap_and_locale &>"$work/out" || { cat "$work/out"; exit 1; }
}

rm -rf "$work/root"
initramfs "$work/root/boot/EFI/Linux/omarchy_linux-omarchy.efi" uk
verify uefi
((FAILURES == 0)) || fail "a UEFI install with the layout in its UKI failed: $(grep 'not ok' "$work/out")"
echo "ok - a UEFI install is checked in its UKI"

bios_boot uk
verify bios
((FAILURES == 0)) || fail "a BIOS install with the layout in its initramfs failed: $(grep 'not ok' "$work/out")"
echo "ok - a BIOS install is checked in the initramfs its Limine entry loads"

bios_boot us
verify bios
((FAILURES > 0)) || fail "a BIOS install whose initramfs kept us passed"
echo "ok - a BIOS initramfs that lost the layout fails"
