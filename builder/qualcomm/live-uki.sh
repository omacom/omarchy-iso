#!/usr/bin/env bash
#
# Runs inside the live image of an aarch64 build, once the live kernel and
# initramfs exist, with the kernel package's name. Snapdragon laptops get no
# device tree from their firmware, so the live system boots a UKI that carries
# one for every supported laptop, and systemd-stub picks by the machine's SMBIOS
# data. On a machine it has no device tree for, the stub leaves the firmware's
# own tables alone.
set -euo pipefail

kernel=/boot/vmlinuz-$1
initrd=/boot/initramfs-$1.img
uki=/boot/omarchy-live.efi
hwids=/usr/lib/systemd/boot/hwids/aa64

# The kernel package keeps its Snapdragon device trees under its own name.
dtb_dir=/boot/dtbs/$1/qcom

# Include supported Snapdragon generations.
# EL2 variants share hardware IDs with their base DTBs and would be ambiguous.
shopt -s nullglob
dtbs=()
for dtb in "$dtb_dir"/x1*.dtb "$dtb_dir"/hamoa*.dtb "$dtb_dir"/purwa*.dtb "$dtb_dir"/glymur*.dtb "$dtb_dir"/mahua*.dtb "$dtb_dir"/kalambo*.dtb "$dtb_dir"/sc8280xp*.dtb "$dtb_dir"/sc8180x*.dtb "$dtb_dir"/sdm850*.dtb "$dtb_dir"/msm8998-{asus,hp,lenovo}*.dtb "$dtb_dir"/sc7180-{acer,apcsilmic,ecs,lenovo,samsung,tclcomm}*.dtb "$dtb_dir"/sc7280-samsung*.dtb; do
  [[ $dtb == *-el2.dtb ]] && continue
  dtbs+=("$dtb")
done
# systemd-stub only picks a tree whose compatible a hardware ID file names, so
# the image carries those and leaves out the rest, which no SMBIOS data can
# select. Every tree is a section, and the stub's header has room for about
# 120 (see below). A compatible string starts its property's value or follows
# another's terminating zero, and ends with one of its own.
if [[ -d $hwids ]]; then
  hwid_compatibles=$(grep -rhoE --include='*.json' '"compatible"[[:space:]]*:[[:space:]]*"[^"]+"' "$hwids" |
    sed -E 's/.*"([^"]+)"$/\1/' | sort -u || true)
  if [[ -n $hwid_compatibles ]]; then
    alternatives=$(while IFS= read -r compatible; do
      printf '%s' "$compatible" | od -An -v -tx1 | tr -d '\n'
      echo
    done <<<"$hwid_compatibles" | sed 's/^ //' | paste -sd '|' -)
    named="( 00| 00 00 00 03( [0-9a-f]{2}){8}) (${alternatives}) 00"
    selectable=()
    for dtb in "${dtbs[@]}"; do
      if grep -qE "$named" <(od -An -v -tx1 "$dtb" | tr -d '\n'); then
        selectable+=("$dtb")
      fi
    done
    if (( ${#selectable[@]} > 0 )); then
      echo "live-uki: ${#selectable[@]} of ${#dtbs[@]} device trees have hardware IDs"
      dtbs=("${selectable[@]}")
    fi
  fi
fi

if (( ${#dtbs[@]} == 0 )); then
  echo "live-uki: $1 ships no Windows-on-ARM device trees under $dtb_dir; this image will not boot a Snapdragon laptop"
  exit 0
fi

for f in "$kernel" "$initrd"; do
  if [[ ! -s $f ]]; then
    echo "live-uki: $f is missing; the live kernel setup should have produced it" >&2
    exit 1
  fi
done
if ! command -v ukify >/dev/null; then
  echo "live-uki: ukify not found; is systemd-ukify among the live packages?" >&2
  exit 1
fi
if [[ ! -d $hwids ]]; then
  echo "live-uki: no SMBIOS-ID database at $hwids (systemd >= 260 ships it)" >&2
  exit 1
fi

# The direct-boot initramfs remains untouched. The Qualcomm UKI needs its
# firmware drivers and DT-named blobs before it can find USB installation media.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s\n' "${dtbs[@]}" >"$work/dtbs.list"
OMARCHY_QCOM_DTBS_FILE="$work/dtbs.list" mkinitcpio \
  -k "$kernel" -c /etc/mkinitcpio.conf.d/archiso.conf \
  -A qcom_early_startup -g "$work/initramfs.img"
initrd="$work/initramfs.img"

# Each tree is a section of its own. ukify writes every section's header into
# the room the stub leaves before its first section and stops with "Not enough
# header space" once it is full. With systemd 262's aa64 stub that is 120
# trees beside .linux, .initrd, .hwids, .osrel, .uname and .sbat, which is why
# the list above keeps only trees with hardware IDs. At about
# 190 KB a tree, the size limit below leaves room for more than that.
args=()
for dtb in "${dtbs[@]}"; do
  args+=("--devicetree-auto=$dtb")
done

echo "live-uki: wrapping $kernel and $initrd with ${#dtbs[@]} device trees"
ukify build \
  --linux="$kernel" \
  --initrd="$initrd" \
  --hwids="$hwids" \
  "${args[@]}" \
  --output="$uki"

# Verify that ukify embedded every required section.
sections="$(ukify inspect "$uki")"
n_dtb="$(grep -c '^\.dtbauto:' <<<"$sections" || true)"
if ! grep -q '^\.hwids:' <<<"$sections"; then
  echo "live-uki: $uki has no .hwids section" >&2
  exit 1
fi
if (( n_dtb != ${#dtbs[@]} )); then
  echo "live-uki: $uki has $n_dtb .dtbauto sections, expected ${#dtbs[@]}" >&2
  exit 1
fi
# GRUB reads the whole UKI into memory to chainload it. omarchy-iso#128 showed
# GRUB failing to place a 241 MiB initramfs in a Lenovo Yoga's EFI memory map;
# the UKI booting on the laptops today is about 227 MiB. Keep it near that, so
# growth (embedded firmware, a bigger initramfs) fails the build rather than
# reaching laptops untested.
uki_bytes=$(stat -c %s "$uki")
uki_limit=$((256 * 1024 * 1024))
if (( uki_bytes > uki_limit )); then
  echo "live-uki: $uki is $uki_bytes bytes, over the $uki_limit limit" >&2
  exit 1
fi
echo "live-uki: $uki: $uki_bytes bytes, $n_dtb .dtbauto sections, .hwids present"
