#!/usr/bin/env bash
#
# Usage: stage-medium-firmware.sh KERNEL-PACKAGE OUTPUT-DIR FIRMWARE-PACKAGE...
#
# Stages, as plain files on the medium with a SHA256SUMS list, the firmware
# each Snapdragon laptop needs to start its ADSP in the live initramfs
# (qualcomm/early-startup copies its own board's files from here). The UKI
# cannot carry them for every laptop: GRUB has to place the whole UKI in
# memory (omarchy-iso#128).
#
# What to stage comes from the device trees, not from file names: the same
# trees live-uki.sh embeds, and of their firmware owners only the files they
# require. A board whose ADSP firmware is named some other way is staged all
# the same. A wanted file a package ships as a symlink is staged as the file
# it names, so it is listed in SHA256SUMS like any other.
set -euo pipefail

kernel_package=$1
out=$2
shift 2

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/kernel"
bsdtar -xf "$kernel_package" -C "$work/kernel" --include='boot/dtbs/*/qcom/*.dtb'

# The selection live-uki.sh makes, so the medium serves the UKI's boards.
# test_qcom_shared_boot.py checks that the two loops name the same trees.
shopt -s nullglob
dtb_dirs=("$work"/kernel/boot/dtbs/*/qcom)
if (( ${#dtb_dirs[@]} != 1 )); then
  echo "stage-medium-firmware: $kernel_package has ${#dtb_dirs[@]} Qualcomm device-tree directories, expected 1" >&2
  exit 1
fi
dtb_dir=${dtb_dirs[0]}
dtbs=()
for dtb in "$dtb_dir"/x1*.dtb "$dtb_dir"/hamoa*.dtb "$dtb_dir"/glymur*.dtb "$dtb_dir"/mahua*.dtb "$dtb_dir"/sc8280xp*.dtb; do
  [[ $dtb == *-el2.dtb ]] && continue
  dtbs+=("$dtb")
done
shopt -u nullglob
if (( ${#dtbs[@]} == 0 )); then
  echo "stage-medium-firmware: $kernel_package ships no Snapdragon device trees" >&2
  exit 1
fi
printf '%s\n' "${dtbs[@]}" >"$work/dtbs.list"
python3 "$here/early-firmware.py" --required "$work/dtbs.list" >"$work/wanted"

rm -rf "$out"
mkdir -p "$out"
for package in "$@"; do
  # Package members for the wanted names, in any compression the kernel's
  # firmware loader accepts.
  mapfile -t members < <(bsdtar -tf "$package" | awk '
    NR == FNR {
      want["usr/lib/firmware/" $0] = 1
      want["usr/lib/firmware/" $0 ".xz"] = 1
      want["usr/lib/firmware/" $0 ".zst"] = 1
      next
    }
    $0 in want
  ' "$work/wanted" -)
  (( ${#members[@]} )) || continue
  # Unpack the package's whole firmware tree, so a symlink resolves to the
  # file it names, and copy out only the wanted members. A link may name only
  # a file inside that tree: package signatures do not constrain link
  # targets, and an absolute or ../ link would put a builder file on the ISO.
  rm -rf "$work/package"
  mkdir -p "$work/package"
  bsdtar -xf "$package" -C "$work/package" --include='usr/lib/firmware/*'
  firmware_root=$(realpath -e -- "$work/package/usr/lib/firmware")
  for member in "${members[@]}"; do
    target="$out/${member#usr/lib/firmware/}"
    [[ ! -e $target ]] || continue
    source=$(realpath -e -- "$work/package/$member" 2>/dev/null) || source=''
    if [[ -z $source || ! -f $source ]]; then
      echo "stage-medium-firmware: ${package##*/}: $member does not resolve to a file" >&2
      exit 1
    fi
    if [[ $source != "$firmware_root"/* ]]; then
      echo "stage-medium-firmware: ${package##*/}: $member links outside the package's firmware" >&2
      exit 1
    fi
    mkdir -p "${target%/*}"
    cp -- "$source" "$target"
  done
done

(cd "$out" && find . -type f -printf '%P\0' | sort -z | xargs -0r sha256sum >"$work/SHA256SUMS")
mv "$work/SHA256SUMS" "$out/SHA256SUMS"
staged=$(wc -l <"$out/SHA256SUMS")
if (( staged == 0 )); then
  echo "stage-medium-firmware: none of the $# firmware packages ships a file the device trees require" >&2
  exit 1
fi

# Names no package provides belong to boards whose firmware the UKI already
# carries (linux-firmware-qcom) or that no package supports yet; the hook
# keeps the legacy path for the latter, as before.
unstaged=$(awk '
  NR == FNR { staged[$2] = 1; next }
  !(($0 in staged) || (($0 ".xz") in staged) || (($0 ".zst") in staged)) { n++ }
  END { print n + 0 }
' "$out/SHA256SUMS" "$work/wanted")
echo "stage-medium-firmware: $staged files, $(du -sm "$out" | cut -f1) MiB, for ${#dtbs[@]} device trees; $unstaged required names come from no OEM package"
