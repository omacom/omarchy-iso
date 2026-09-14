#!/bin/bash
#
# Put the offline mirror on the ISO as ordinary files, in their own directory
# in the ISO9660 tree beside the root image, instead of packing them into a
# filesystem image. The live system bind-mounts that directory over
# /var/cache/omarchy/mirror/offline, where the mirror has always been.
#
# mkarchiso passes -iso-level 3 -full-iso9660-filenames -rational-rock, so the
# long package names and the offline.db symlink survive verbatim.
#
# Usage: stage-mirror-files.sh <mirror-dir> <shipped-list> <destination-dir>

set -euo pipefail

mirror_dir="${1:-}"
shipped_list="${2:-}"
dest="${3:-}"

if [[ -z $mirror_dir || -z $shipped_list || -z $dest ]]; then
  echo "Usage: stage-mirror-files.sh <mirror-dir> <shipped-list> <destination-dir>" >&2
  exit 1
fi
[[ -d $mirror_dir ]] || { echo "ERROR: mirror directory not found: $mirror_dir" >&2; exit 1; }
[[ -f $shipped_list ]] || { echo "ERROR: shipped list not found: $shipped_list" >&2; exit 1; }

rm -rf "$dest"
mkdir -p "$dest"

shopt -s nullglob
declare -a databases=("$mirror_dir"/offline.db* "$mirror_dir"/offline.files*)
shopt -u nullglob
if (( ${#databases[@]} == 0 )); then
  echo "ERROR: no repo database in $mirror_dir; run repo-add before staging" >&2
  exit 1
fi
# -a keeps offline.db -> offline.db.tar.gz a symlink; Rock Ridge carries it
# onto the ISO as one.
cp -a "${databases[@]}" "$dest/"

shipped_count=0
while IFS= read -r filename; do
  [[ -n $filename ]] || continue
  if [[ $filename == */* || $filename != *.pkg.tar.* || $filename == *.sig ]]; then
    echo "ERROR: invalid package filename in $shipped_list: $filename" >&2
    exit 1
  fi
  if [[ ! -f "$mirror_dir/$filename" ]]; then
    echo "ERROR: shipped selection names a package missing from the mirror: $filename" >&2
    exit 1
  fi
  cp -a "$mirror_dir/$filename" "$dest/"
  [[ -f "$mirror_dir/$filename.sig" ]] && cp -a "$mirror_dir/$filename.sig" "$dest/"
  shipped_count=$((shipped_count + 1))
done <"$shipped_list"

if (( shipped_count == 0 )); then
  echo "ERROR: refusing to stage a mirror with no packages" >&2
  exit 1
fi

echo "Mirror files: $shipped_count packages, $(du -sh "$dest" | cut -f1) at $dest"
