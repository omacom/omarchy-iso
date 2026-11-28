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
# An image with Omarchy's boot splash gets no pre-built UKI, only the N1x
# layer: its hook runs only in the busybox initramfs each install builds.
splash_gate=$(awk '
  !in_block && /^  prebuilt_ukis=1$/ { in_block = 1 }
  in_block { print; if (/^  fi$/) exit }
' "$builder")
[[ $splash_gate == *omarchy-splash* ]] || fail "could not extract the boot splash's pre-built UKI gate"
uki_launches=$(awk '
  !in_block && /^  uki_tmp=""$/ { in_block = 1 }
  in_block { print; if (/^  fi$/) exit }
' "$builder")
[[ $uki_launches == *build_generic_uki_in* ]] || fail "could not extract the parallel pre-built UKI launches"
uki_branch=$(awk '
  !in_block && /^  if \[\[ -n \$\{OMARCHY_SNAPDRAGON:-\} \]\]; then$/ { in_block = 1 }
  in_block { print; if (/^  n1x_script=/) n1x = 1; if (n1x && /^  fi$/) exit }
' "$builder")
[[ $uki_branch == *build_n1x_prebuilt_uki* ]] || fail "could not extract the OMARCHY_SNAPDRAGON and N1x pre-built UKI branches"

# run_uki_build <name> <splash: 1 or ""> <snapdragon: 1 or ""> <parallel: 1 or 0>
# runs those steps in the builder's order on an aarch64 host with n1x.sh. Each
# builder it starts writes its name to $work/calls-<name>.
run_uki_build() {
  # One local each: within one, a later name still sees the caller's value.
  local name=$1
  local splash=$2
  local snapdragon=$3
  local parallel=$4
  local root="$work/root-$name" log="$work/chroot-$name.log" calls="$work/calls-$name"
  mkdir -p "$root/var/lib/omarchy-iso" "$root/etc/kernel" "$root/usr/lib/initcpio/install" \
    "$root/usr/share/omarchy/install/hardware"
  # What the parallel launches copy out of the image, and the N1x script.
  touch "$root"/etc/{vconsole.conf.prebuilt-uki,mkinitcpio-prebuilt-uki.conf,kernel/cmdline.prebuilt-uki} \
    "$root/usr/lib/initcpio/install/omarchy-vconsole-room" "$root/usr/share/omarchy/install/hardware/n1x.sh"
  if [[ -n $splash ]]; then
    install -D /dev/null "$root/etc/initcpio/install/omarchy-splash"
  else
    printf 'stale' >"$root/var/lib/omarchy-iso/prebuilt-uki.efi"
  fi
  : >"$calls"
  rm -f "$log"
  # shellcheck disable=SC2034 # read by the builder's steps run through eval
  (
    image_kver="7.3.6-2-omarchy"
    OMARCHY_SNAPDRAGON=$snapdragon
    OMARCHY_FAST_COMPRESSION=
    prebuilt_async=$parallel
    uname() { echo aarch64; }
    arch-chroot() {
      printf '%s\n' "$*" >>"$log"
      printf 'built-uki' >"$1/var/lib/omarchy-iso/prebuilt-uki.efi"
      echo generic >>"$calls"
    }
    with_image_overlay() {
      case $1 in
        build_generic_uki_in) echo generic ;;
        *) echo "$1" ;;
      esac >>"$calls"
    }
    build_qualcomm_prebuilt_uki() {
      printf 'built-qualcomm-uki' >"$root/var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi"
      echo qualcomm >>"$calls"
    }
    build_n1x_prebuilt_uki() { echo n1x >>"$calls"; }
    eval "$splash_gate"
    eval "$uki_launches"
    eval "$uki_branch"
    wait
  ) >/dev/null
}

# expect_builds <name> <the builders it starts, sorted>
expect_builds() {
  local builds
  builds=$(sort "$work/calls-$1" | paste -sd ' ')
  [[ $builds == "$2" ]] || fail "$1 started ${builds:-no builder}, not ${2:-none}"
}

for parallel in 0 1; do
  run_uki_build "snapdragon-$parallel" "" 1 "$parallel"
  expect_builds "snapdragon-$parallel" qualcomm
  run_uki_build "ordinary-$parallel" "" "" "$parallel"
  expect_builds "ordinary-$parallel" "generic n1x"
done
[[ ! -e $work/chroot-snapdragon-0.log ]] || fail "Snapdragon build must not invoke arch-chroot/mkinitcpio for generic UKI: $(cat "$work/chroot-snapdragon-0.log")"
[[ ! -e $work/root-snapdragon-0/var/lib/omarchy-iso/prebuilt-uki.efi ]] || fail "Snapdragon build must remove stale prebuilt-uki.efi"
[[ $(cat "$work/root-snapdragon-0/var/lib/omarchy-iso/prebuilt-uki-qualcomm.efi") == "built-qualcomm-uki" ]] ||
  fail "Snapdragon aarch64 build did not invoke build_qualcomm_prebuilt_uki"
[[ -f $work/chroot-ordinary-0.log ]] || fail "ordinary build must invoke arch-chroot/mkinitcpio"
grep -Fq "mkinitcpio" "$work/chroot-ordinary-0.log" || fail "ordinary build did not invoke mkinitcpio: $(cat "$work/chroot-ordinary-0.log")"
grep -Fq -- "-U /var/lib/omarchy-iso/prebuilt-uki.efi" "$work/chroot-ordinary-0.log" ||
  fail "ordinary build did not target prebuilt-uki.efi: $(cat "$work/chroot-ordinary-0.log")"
[[ $(cat "$work/root-ordinary-0/var/lib/omarchy-iso/prebuilt-uki.efi") == "built-uki" ]] ||
  fail "ordinary build did not write prebuilt-uki.efi"
echo "ok - Snapdragon builds remove stale generic UKI without calling mkinitcpio, ordinary builds still build it"

for parallel in 0 1; do
  run_uki_build "splash-snapdragon-$parallel" 1 1 "$parallel"
  expect_builds "splash-snapdragon-$parallel" ""
  run_uki_build "splash-ordinary-$parallel" 1 "" "$parallel"
  expect_builds "splash-ordinary-$parallel" n1x
done
echo "ok - an image with the boot splash gets no generic or Qualcomm UKI, and still builds the N1x layer"

# The builder invokes mkinitcpio -c/-U directly and never through a preset.
# Leaving an orphaned mkinitcpio preset pointing at prebuilt-uki.efi caused
# unmasked 90-mkinitcpio-install.hook runs inside build-try-layer.sh to build
# ~239 MiB kms UKIs into both omarchy-try.sfs and omarchy-try-nvidia-open.sfs.
if grep -Fq 'default_uki="/var/lib/omarchy-iso/prebuilt-uki.efi"' "$builder"; then
  fail "build-root-image.sh still writes an orphaned mkinitcpio preset for prebuilt-uki.efi"
fi
grep -Fq 'bash /builder/build-try-layer.sh "$root" "$OMARCHY_TRY_LAYER" "${OMARCHY_TRY_CHANNEL:-stable}" "$effective_pacman_conf"' "$builder" ||
  fail "build-root-image.sh must pass effective_pacman_conf (with boot hooks masked) to build-try-layer.sh"
echo "ok - build-root-image.sh writes no orphaned UKI preset and masks boot hooks for build-try-layer.sh"
