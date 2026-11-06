#!/bin/bash
#
# The live initramfs loads i915 at once only on the Intel GPUs that need no
# firmware, listed in i915-early.ids from the kernel's own table: the
# generations before Skylake. The hook decides by PCI vendor, class and
# device ID, so a newer Intel GPU, a non-Intel one, or an Intel device that
# is not a display controller must all be left to the live root.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/configs/airootfs/etc/initcpio/hooks/omarchy-i915"
IDS="$ROOT/configs/airootfs/usr/share/omarchy-iso/i915-early.ids"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
# wanted <description> yes|no: the hook's verdict on the fake PCI bus
wanted() { if omarchy_i915_wanted; then v=yes; else v=no; fi; if [[ $v == "$2" ]]; then ok "$1"; else fail "$1: wanted=$v"; fi; }
listed() { if grep -qx "$2" "$IDS"; then v=yes; else v=no; fi; if [[ $v == "$3" ]]; then ok "$1"; else fail "$1"; fi; }

count=$(grep -cE '^[0-9a-f]{4}$' "$IDS")
if (( count >= 100 )); then ok "$count device IDs listed"; else fail "only $count device IDs listed"; fi
listed "GM45 (the ThinkPad X200) is listed" 2a42 yes
listed "Broadwell is listed" 1616 yes
listed "Skylake is not listed, it wants firmware" 1916 no
listed "Meteor Lake is not listed, it needs GuC firmware" 7d55 no
if grep -vE '^(#|[0-9a-f]{4}$)' "$IDS" | grep -q .; then fail "a line is neither a comment nor a 4-digit hex ID"; else ok "every line is a comment or a 4-digit hex ID"; fi

# shellcheck source=/dev/null
source "$HOOK"
export OMARCHY_I915_IDS="$IDS" OMARCHY_PCI_DEVICES="$work/pci"
bus() { rm -rf "$work/pci"; mkdir -p "$work/pci"; }
device() { mkdir -p "$work/pci/$1"; printf '0x%s\n' "$2" >"$work/pci/$1/vendor"; printf '0x%s\n' "$3" >"$work/pci/$1/device"; printf '0x%s\n' "$4" >"$work/pci/$1/class"; }

bus; device 0000:00:02.0 8086 2a42 030000
wanted "GM45 display controller" yes
bus; device 0000:00:02.0 8086 1916 030000
wanted "Skylake display controller: left to the live root" no
bus; device 0000:01:00.0 1002 731f 030000
wanted "an AMD GPU: left alone" no
bus; device 0000:00:14.0 8086 2a42 0c0330
wanted "an Intel device that is not a display controller: ignored" no
bus; device 0000:00:02.0 8086 2a42 030000; device 0000:01:00.0 10de 1c82 030000
wanted "GM45 beside another GPU" yes
bus
wanted "no PCI devices: nothing" no
bus; device 0000:00:02.0 8086 2a42 030000
OMARCHY_I915_IDS="$work/missing" wanted "no ID list: nothing" no

# run_hook marks i915 as loading for as long as modprobe runs; run_latehook,
# just before switch_root, hands the redraw to the live root's helper inside
# the new root while it still is.
export OMARCHY_RUN_DIR="$work/run" OMARCHY_SYSROOT="$work/sysroot" OMARCHY_INIT="$work/init"
: >"$work/init"
helper="$work/sysroot/usr/local/bin/omarchy-console-logo-redraw"
mkdir -p "${helper%/*}"; printf '#!/bin/bash\n' >"$helper"; chmod 755 "$helper"
modprobe() { sleep 0.3; echo "modprobe: an error" >&2; }
chroot() { echo "chroot $*" >>"$work/chroot.log"; }
bus; device 0000:00:02.0 8086 2a42 030000
run_hook 2>"$work/hook-stderr"
if [[ -e $work/run/i915-loading ]]; then ok "run_hook marks i915 as loading"; else fail "run_hook left no i915-loading marker"; fi
run_latehook
wait
if [[ -s $work/hook-stderr ]]; then fail "the background job wrote to the console: $(cat "$work/hook-stderr")"; else ok "the background job's errors go nowhere, not to the console"; fi
want="chroot $work/sysroot /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin /usr/local/bin/omarchy-console-logo-redraw --wait"
if [[ $(cat "$work/chroot.log" 2>/dev/null) == "$want" ]]; then ok "run_latehook starts the redraw helper inside the new root while i915 loads"; else fail "run_latehook ran: $(cat "$work/chroot.log" 2>/dev/null)"; fi
if [[ -e $work/run/i915-loading ]]; then fail "the marker stayed after modprobe returned"; else ok "the marker goes when modprobe returns"; fi
rm -f "$work/chroot.log"
run_latehook; wait
if [[ -e $work/chroot.log ]]; then fail "run_latehook started the helper with i915 loaded"; else ok "run_latehook does nothing once i915 is loaded"; fi
# After switch_root (no /init) the job runs builtins only: rm went with the
# initramfs, so the marker stays for the live root's helper to clear.
rm -f "$work/init"
run_hook; wait
if [[ -e $work/run/i915-loading ]]; then ok "after switch_root the marker stays for the live root's helper"; else fail "the job ran rm after switch_root"; fi
rm -f "$work/run/i915-loading"; : >"$work/init"
: >"$work/run/i915-loading"; rm -f "$helper"
run_latehook; wait
if [[ -e $work/chroot.log ]]; then fail "run_latehook ran without a helper in the new root"; else ok "run_latehook does nothing without the helper in the new root"; fi
rm -f "$work/run/i915-loading"
# The half-size VGA logo alone starts it too: a GPU driver from the live
# root will take the VGA console away.
printf '#!/bin/bash\n' >"$helper"; chmod 755 "$helper"; : >"$work/run/console-logo-vga"; rm -f "$work/chroot.log"
run_latehook; wait
if [[ $(cat "$work/chroot.log" 2>/dev/null) == "$want" ]]; then ok "run_latehook starts the helper while the VGA logo is up"; else fail "run_latehook with the VGA logo up ran: $(cat "$work/chroot.log" 2>/dev/null)"; fi
rm -f "$work/run/console-logo-vga" "$work/chroot.log"
bus; device 0000:00:02.0 8086 1916 030000
run_hook; wait
if [[ -e $work/run/i915-loading ]]; then fail "a Skylake GPU got the marker"; else ok "no marker where i915 is not loaded early"; fi

exit "$((failures > 0))"
