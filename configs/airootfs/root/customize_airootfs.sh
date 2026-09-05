#!/bin/bash
#
# Runs inside the live root while mkarchiso builds it, after the live packages
# were pacstrapped from the bundled mirror. Drop the package files the root
# image already provides (build-iso.sh lists what to keep); nothing at install
# time can download them, since the same versions are installed from the
# image. The repo db is left complete so `pacman -S --needed` over package
# lists that mix image packages with new ones still resolves every name.

set -euo pipefail

mirror=/var/cache/omarchy/mirror/offline
shipped_list=/usr/share/omarchy-iso/offline-mirror.shipped

[[ -f $shipped_list && -d $mirror ]] || exit 0

declare -A shipped=()
while IFS= read -r filename; do
  [[ -n $filename ]] && shipped["$filename"]=1
done <"$shipped_list"

if (( ${#shipped[@]} == 0 )); then
  echo "ERROR: refusing to prune the shipped mirror with an empty selection" >&2
  exit 1
fi
for filename in "${!shipped[@]}"; do
  if [[ ! -f $mirror/$filename ]]; then
    echo "ERROR: shipped mirror selection names a missing package: $filename" >&2
    exit 1
  fi
done

removed=0
for path in "$mirror"/*.pkg.tar.*; do
  filename=${path##*/}
  [[ $filename == *.sig ]] && continue
  [[ -n ${shipped[$filename]+x} ]] && continue
  rm -f -- "$path" "$path.sig"
  removed=$((removed + 1))
done
echo "Removed $removed package files the root image already provides; ${#shipped[@]} remain."
