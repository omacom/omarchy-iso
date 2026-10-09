#!/bin/bash
#
# Index the offline mirror: <dir>/offline.db.tar.gz and offline.files.tar.gz
# from every package in <dir>, the same databases one repo-add call writes.
#
#   index-offline-mirror.sh <dir> [jobs]
#
# repo-add handles one package at a time, and for each it hashes the archive
# and lists its files, which means decompressing all of it. A database is only
# a tar of one directory per package, so the packages are dealt out to one
# repo-add per CPU, each writing its own database, and the pieces are put
# together afterwards.
set -euo pipefail

dir=$(realpath "$1")
jobs=${2:-$(nproc)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mapfile -t packages < <(find "$dir" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | sort)
(( ${#packages[@]} > 0 )) || { echo "index-offline-mirror: no packages in $dir" >&2; exit 1; }
(( jobs > ${#packages[@]} )) && jobs=${#packages[@]}
(( jobs >= 1 )) || jobs=1

# Deal the sorted list out round-robin: big and small packages spread evenly.
for (( i = 0; i < jobs; i++ )); do mkdir "$work/$i"; done
for (( i = 0; i < ${#packages[@]}; i++ )); do
  printf '%s\0' "${packages[i]}" >>"$work/$(( i % jobs ))/list"
done

pids=()
for (( i = 0; i < jobs; i++ )); do
  xargs -0 -a "$work/$i/list" repo-add -q "$work/$i/offline.db.tar.gz" >"$work/$i/log" 2>&1 &
  pids+=($!)
done
failed=0
for (( i = 0; i < jobs; i++ )); do
  if ! wait "${pids[i]}"; then
    failed=1
    echo "index-offline-mirror: repo-add failed on part $i:" >&2
    cat "$work/$i/log" >&2
  fi
done
(( failed == 0 )) || exit 1

mkdir "$work/db" "$work/files"
for (( i = 0; i < jobs; i++ )); do
  bsdtar -xf "$work/$i/offline.db.tar.gz" -C "$work/db"
  bsdtar -xf "$work/$i/offline.files.tar.gz" -C "$work/files"
done

# One repo-add keeps a single entry per package name. Apart, two versions of
# one name would both survive, so that is an error here rather than a choice.
entries=$(find "$work/db" -mindepth 1 -maxdepth 1 -type d | wc -l)
names=$(cat "$work"/db/*/desc | awk '/^%NAME%$/ { getline; print }' | sort -u | wc -l)
if (( entries != ${#packages[@]} || names != entries )); then
  echo "index-offline-mirror: ${#packages[@]} packages gave $entries entries for $names names; two versions of one package?" >&2
  exit 1
fi

rm -f "$dir"/offline.db* "$dir"/offline.files*
for kind in db files; do
  find "$work/$kind" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort |
    bsdtar -czf "$dir/offline.$kind.tar.gz" -C "$work/$kind" -T -
  ln -s "offline.$kind.tar.gz" "$dir/offline.$kind"
done
echo "Indexed ${#packages[@]} packages with $jobs repo-add processes."
