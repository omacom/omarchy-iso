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

# The N1x UKI is built with the MODULES lines omarchy's n1x.sh writes, read out
# of its heredocs and normalized the way the installer reads the target's
# (_initramfs_module_lines), or no N1x would ever match it.
eval "$(sed -n '/^n1x_module_lines() {$/,/^}$/p' "$builder")"
declare -F n1x_module_lines >/dev/null || fail "the builder has no n1x_module_lines"
cat >"$work/n1x.sh" <<'SCRIPT'
cat > /etc/mkinitcpio.conf.d/omarchy-n1x-input.conf <<'CONF'
MODULES+=(i2c_mt65xx   i2c_hid_acpi)
CONF
if true; then
  cat > /etc/mkinitcpio.conf.d/nvidia.conf <<'CONF'
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
CONF
fi
# MODULES+=(commented out)
SCRIPT
[[ $(n1x_module_lines "$work/n1x.sh" | paste -sd '|') == "MODULES+=(i2c_mt65xx i2c_hid_acpi)|MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" ]] ||
  fail "n1x_module_lines read: $(n1x_module_lines "$work/n1x.sh" | paste -sd '|')"
echo "ok - the N1x UKI takes its modules from n1x.sh, as the installer will read them"

# The N1x's 61 MiB kernel and NVIDIA firmware put its UKI past 128 MiB; the N1x
# boots one that size on every installed system, so it has its own ceiling.
eval "$(sed -n '/^n1x_prebuilt_uki_size_ok() {$/,/^}$/p' "$builder")"
truncate -s 190M "$work/n1x.efi"
truncate -s 257M "$work/n1x-big.efi"
n1x_prebuilt_uki_size_ok "$work/n1x.efi" >/dev/null 2>&1 || fail "a 190 MiB N1x UKI is refused"
if n1x_prebuilt_uki_size_ok "$work/n1x-big.efi" >/dev/null 2>&1; then fail "a 257 MiB N1x UKI is accepted"; fi
echo "ok - the N1x UKI has a ceiling of its own"

# Snapdragon ISOs install only Snapdragon laptops, which always build their own
# UKI with board firmware and device trees; skip the unused generic UKI so it
# does not bloat the root image, while ordinary builds still invoke mkinitcpio.
uki_branch=$(awk '
  !in_block && /^  if \[\[ -n \$\{OMARCHY_SNAPDRAGON:-\} \]\]; then$/ { in_block = 1 }
  in_block { print; if (/^  fi$/) exit }
' "$builder")
[[ -n $uki_branch ]] || fail "could not extract the OMARCHY_SNAPDRAGON pre-built UKI branch"

run_uki_branch() {
  local snapdragon=$1 root="$work/root-${snapdragon:-ordinary}" log="$work/chroot-${snapdragon:-ordinary}.log"
  mkdir -p "$root/var/lib/omarchy-iso"
  printf 'stale' >"$root/var/lib/omarchy-iso/prebuilt-uki.efi"
  rm -f "$log"
  (
    image_kver="7.3.6-2-omarchy"
    OMARCHY_SNAPDRAGON=$snapdragon
    arch-chroot() {
      printf '%s\n' "$*" >>"$log"
      printf 'built-uki' >"$1/var/lib/omarchy-iso/prebuilt-uki.efi"
    }
    eval "$uki_branch"
  ) >/dev/null
}

run_uki_branch 1
[[ ! -e $work/chroot-1.log ]] || fail "Snapdragon build must not invoke arch-chroot/mkinitcpio: $(cat "$work/chroot-1.log")"
[[ ! -e $work/root-1/var/lib/omarchy-iso/prebuilt-uki.efi ]] || fail "Snapdragon build must remove stale prebuilt-uki.efi"

run_uki_branch ""
[[ -f $work/chroot-ordinary.log ]] || fail "ordinary build must invoke arch-chroot/mkinitcpio"
grep -Fq "mkinitcpio" "$work/chroot-ordinary.log" || fail "ordinary build did not invoke mkinitcpio: $(cat "$work/chroot-ordinary.log")"
grep -Fq -- "-U /var/lib/omarchy-iso/prebuilt-uki.efi" "$work/chroot-ordinary.log" ||
  fail "ordinary build did not target prebuilt-uki.efi: $(cat "$work/chroot-ordinary.log")"
[[ $(cat "$work/root-ordinary/var/lib/omarchy-iso/prebuilt-uki.efi") == "built-uki" ]] ||
  fail "ordinary build did not write prebuilt-uki.efi"
echo "ok - Snapdragon builds remove stale generic UKI without calling mkinitcpio, ordinary builds still build it"
