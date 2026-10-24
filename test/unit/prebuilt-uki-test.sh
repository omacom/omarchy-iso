#!/bin/bash
#
# The UKI that builder/build-root-image.sh pre-builds into the root image boots
# every machine that keeps the defaults, so it must stay small enough for the
# boot loader to place: Limine boots a UKI as an EFI chainload and needs one
# contiguous block below 4 GiB for it, and a ~250 MB UKI panics with "High
# memory allocator: Out of memory" on some laptops (omacom/omarchy#5980), the
# same failure class as GRUB with the 241 MiB live initramfs (#128).

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$ROOT/builder/build-root-image.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The UKI is built with autodetect skipped, for no machine in particular. The
# kms hook would then add every DRM driver's firmware (nouveau's GSP firmware
# alone is ~110 MB); without it the LUKS prompt draws on the firmware
# framebuffer (simpledrm), and the installed system's own rebuilds, which
# autodetect, keep kms.
hooks=$(sed -n '/<<'"'"'CONF'"'"'$/,/^CONF$/p' "$builder" | sed -n 's/^HOOKS=(\(.*\))$/\1/p')
[[ -n $hooks ]] || fail "no HOOKS line in the pre-built UKI's mkinitcpio config"
grep -q -- '-S autodetect' "$builder" || fail "the pre-built UKI no longer skips autodetect; revisit this test"
[[ " $hooks " != *" kms "* ]] || fail "the pre-built UKI keeps the kms hook without autodetect: every GPU's firmware lands in it"
echo "ok - the pre-built UKI leaves out kms, which without autodetect bundles every GPU's firmware"

# And whatever goes into it, a UKI over the limit stops the build.
eval "$(sed -n '/^prebuilt_uki_size_ok() {$/,/^}$/p' "$builder")"
declare -F prebuilt_uki_size_ok >/dev/null || fail "the builder has no prebuilt_uki_size_ok"
truncate -s 96M "$work/small.efi"
truncate -s 129M "$work/big.efi"
prebuilt_uki_size_ok "$work/small.efi" >/dev/null 2>&1 || fail "a 96 MiB UKI is refused"
if prebuilt_uki_size_ok "$work/big.efi" >/dev/null 2>"$work/err"; then fail "a 129 MiB UKI is accepted"; fi
grep -q "over the" "$work/err" || fail "the refusal does not say why: $(cat "$work/err")"
echo "ok - a pre-built UKI over 128 MiB stops the build"
