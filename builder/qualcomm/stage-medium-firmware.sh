#!/usr/bin/env bash
#
# Usage: stage-medium-firmware.sh [--trees PACKAGE]... [--zap-out DIR] [--zap-manifest FILE] KERNEL-PACKAGE OUTPUT-DIR FIRMWARE-PACKAGE...
#
# Stages on the medium, with a SHA256SUMS list, the firmware each Snapdragon
# laptop needs to start its ADSP in the live initramfs (qualcomm/early-startup
# copies its own board's files from here). What to stage comes from the device
# trees the live UKI embeds, so the medium holds exactly the names the hook
# will ask for, whatever they are called.
#
# The trees are the kernel package's, and those of each --trees package: one
# the kernel depends on for its device trees, as linux-omarchy-dtbs.
set -euo pipefail

tree_packages=()
zap_out=""
zap_manifest=""
while [[ ${1:-} == --trees || ${1:-} == --zap-out || ${1:-} == --zap-manifest ]]; do
  case $1 in
    --trees) tree_packages+=("$2") ;;
    --zap-out) zap_out=$2 ;;
    --zap-manifest) zap_manifest=$2 ;;
  esac
  shift 2
done
kernel_package=$1
tree_packages=("$kernel_package" "${tree_packages[@]}")
out=$2
shift 2

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# boot/dtbs/<kernel>/qcom/*.dtb lands in $work/qcom.
mkdir -p "$work/qcom"
for package in "${tree_packages[@]}"; do
  # A package without trees is fine as long as another has them, so name the
  # members found rather than pass a pattern bsdtar fails on.
  mapfile -t members < <(bsdtar -tf "$package" | grep -E '^boot/dtbs/[^/]+/qcom/[^/]+\.dtb$' || true)
  (( ${#members[@]} )) || continue
  bsdtar -xf "$package" -C "$work" --strip-components 3 "${members[@]}"
done
dtb_dir=$work/qcom

# The loop live-uki.sh runs; test_qcom_shared_boot.py keeps the two the same.
shopt -s nullglob
dtbs=()
for dtb in "$dtb_dir"/x1*.dtb "$dtb_dir"/hamoa*.dtb "$dtb_dir"/purwa*.dtb "$dtb_dir"/glymur*.dtb "$dtb_dir"/mahua*.dtb "$dtb_dir"/kalambo*.dtb "$dtb_dir"/sc8280xp*.dtb "$dtb_dir"/sc8180x*.dtb "$dtb_dir"/sdm850*.dtb "$dtb_dir"/msm8998-{asus,hp,lenovo}*.dtb "$dtb_dir"/sc7180-{acer,apcsilmic,ecs,lenovo,samsung,tcl}*.dtb "$dtb_dir"/sc7280-{hp,samsung}*.dtb; do
  [[ $dtb == *-el2.dtb ]] && continue
  dtbs+=("$dtb")
done
shopt -u nullglob
(( ${#dtbs[@]} )) || { echo "stage-medium-firmware: no Snapdragon device trees in ${tree_packages[*]##*/}" >&2; exit 1; }
printf '%s\n' "${dtbs[@]}" >"$work/dtbs.list"
python3 "$here/early-firmware.py" --required "$work/dtbs.list" >"$work/wanted"

rm -rf "$out"
mkdir -p "$out"
if (( $# > 0 )); then
  python3 "$here/extract-firmware.py" firmware "$work/wanted" "$work" "$out" "$@"
fi
# A symlink would be left out of SHA256SUMS and the hook could not check it.
if links=$(find "$out" -type l) && [[ -n $links ]]; then
  echo "stage-medium-firmware: firmware shipped as a symlink, which the medium cannot check:" >&2
  echo "$links" >&2
  exit 1
fi
(cd "$out" && find . -type f -printf '%P\0' | sort -z | xargs -0r sha256sum >"$work/SHA256SUMS")
mv "$work/SHA256SUMS" "$out/SHA256SUMS"
staged=$(wc -l <"$out/SHA256SUMS")
(( staged )) || { echo "stage-medium-firmware: no package ships a file the device trees require" >&2; exit 1; }
echo "stage-medium-firmware: $staged files, $(du -sm "$out" | cut -f1) MiB, for ${#dtbs[@]} device trees"

if [[ -n $zap_out ]]; then
  python3 "$here/early-firmware.py" --zap-shaders "$work/dtbs.list" >"$work/wanted-zap"
  mkdir -p "$work/zap-staged" "$zap_out"
  if [[ -s $work/wanted-zap ]] && (( $# > 0 )); then
    mkdir -p "$work/zap-work"
    python3 "$here/extract-firmware.py" firmware "$work/wanted-zap" "$work/zap-work" "$work/zap-staged" "$@"
  fi
  mapfile -t zap_files < <(cd "$work/zap-staged" && find . -type f -printf '%P\n' | sort)
  for rel in "${zap_files[@]}"; do
    install -Dm0644 "$work/zap-staged/$rel" "$zap_out/$rel"
  done
  if [[ -n $zap_manifest ]]; then
    mkdir -p "$(dirname "$zap_manifest")"
    printf '%s\n' "${zap_files[@]}" >"$zap_manifest"
  fi
  echo "stage-medium-firmware: ${#zap_files[@]} GPU zap-shader files staged for live Try Omarchy"
fi
