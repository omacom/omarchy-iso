#!/bin/bash
#
# Index the offline mirror: <dir>/offline.db.tar.gz and offline.files.tar.gz
# from every package in <dir>, the same databases one repo-add call writes.
#
#   index-offline-mirror.sh <dir> [jobs]
#
# When OMARCHY_SYNC_DBS_DIR is set (as during an ISO build), package desc
# entries are copied straight from the synced repository databases (matching
# exact filename and byte size) and repo-add only runs on packages not in any
# sync database (such as --local-source builds). This skips decompressing and
# hashing gigabytes of archives and omits the unused offline.files contents.
#
# Without OMARCHY_SYNC_DBS_DIR, packages are dealt out round-robin to one
# repo-add per CPU, each writing its own database, and the pieces are joined.
set -euo pipefail

dir=$(realpath "$1")
jobs=${2:-$(nproc)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mapfile -t packages < <(find "$dir" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | sort)
(( ${#packages[@]} > 0 )) || { echo "index-offline-mirror: no packages in $dir" >&2; exit 1; }
(( jobs > ${#packages[@]} )) && jobs=${#packages[@]}
(( jobs >= 1 )) || jobs=1

mkdir "$work/db" "$work/files"

if [[ -n ${OMARCHY_SYNC_DBS_DIR:-} && -d ${OMARCHY_SYNC_DBS_DIR:-} ]] && command -v python3 >/dev/null 2>&1; then
  # Extract each sync DB in repository precedence order so overrides (like
  # [omarchy] or [platform] over [extra]) win on any filename match.
  sync_dbs=()
  if [[ -n ${OMARCHY_SYNC_DB_ORDER:-} ]]; then
    for repo in $OMARCHY_SYNC_DB_ORDER; do
      [[ -f "$OMARCHY_SYNC_DBS_DIR/$repo.db" ]] && sync_dbs+=("$OMARCHY_SYNC_DBS_DIR/$repo.db")
    done
  fi
  if (( ${#sync_dbs[@]} == 0 )); then
    shopt -s nullglob
    sync_dbs=("$OMARCHY_SYNC_DBS_DIR"/*.db)
    shopt -u nullglob
  fi

  python3 - "$dir" "$work/db" "$work/missing" "${OMARCHY_LOCAL_PACKAGE_FILES:-}" "${sync_dbs[@]}" <<'PY'
import os, subprocess, sys, tarfile

mirror_dir, db_out, missing_path, local_raw = sys.argv[1:5]
sync_dbs = sys.argv[5:]
local_files = set(local_raw.split())

all_pkgs = {}
for entry in os.scandir(mirror_dir):
    name = entry.name
    if ".pkg.tar." not in name or name.endswith(".sig"):
        continue
    all_pkgs[name] = (entry.path, entry.stat().st_size)

matched = set()

def scan_tar(tf):
    # Arch Linux ARM sync DBs split metadata across <pkg>/desc and
    # <pkg>/depends; copy both so pacman can resolve dependencies from offline.db.
    pkgs = {}
    for m in tf:
        if not m.isfile() or "/" not in m.name:
            continue
        pkg_dir, base = m.name.rsplit("/", 1)
        if base not in ("desc", "depends"):
            continue
        f = tf.extractfile(m)
        if f:
            pkgs.setdefault(pkg_dir, {})[base] = f.read()

    for pkg_dir, files in pkgs.items():
        raw = files.get("desc")
        if not raw:
            continue
        lines = raw.decode("utf-8", errors="replace").splitlines()
        filename = csize = None
        for i, line in enumerate(lines):
            if line == "%FILENAME%" and i + 1 < len(lines):
                filename = lines[i + 1]
            elif line == "%CSIZE%" and i + 1 < len(lines):
                csize = lines[i + 1]
        if not filename or filename in matched or filename in local_files or filename not in all_pkgs:
            continue
        try:
            if csize is not None and int(csize) != all_pkgs[filename][1]:
                continue
        except ValueError:
            continue
        if not pkg_dir or pkg_dir in (".", "..") or "/" in pkg_dir:
            raise ValueError(f"invalid package directory in sync DB: {pkg_dir!r}")
        dst_dir = os.path.join(db_out, pkg_dir)
        os.makedirs(dst_dir, exist_ok=True)
        for base, content in files.items():
            with open(os.path.join(dst_dir, base), "wb") as out:
                out.write(content)
        matched.add(filename)

for db in sync_dbs:
    try:
        with tarfile.open(db, "r:*") as tf:
            scan_tar(tf)
    except tarfile.ReadError:
        p = subprocess.Popen(["bsdtar", "-cf", "-", f"@{db}"], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=p.stdout, mode="r|") as tf:
            scan_tar(tf)
        p.wait()
        if p.returncode != 0:
            sys.exit(p.returncode)

missing = [all_pkgs[name][0] for name in sorted(all_pkgs) if name not in matched]
with open(missing_path, "wb") as f:
    for p in missing:
        f.write(p.encode("utf-8") + b"\0")
PY

  if [[ -s "$work/missing" ]]; then
    xargs -0 -a "$work/missing" repo-add -q "$work/local.db.tar.gz" >"$work/local.log" 2>&1 || {
      echo "index-offline-mirror: repo-add failed on unindexed packages:" >&2
      cat "$work/local.log" >&2
      exit 1
    }
    bsdtar -xf "$work/local.db.tar.gz" -C "$work/db"
  fi
  indexed_note="from sync databases"
else
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

  for (( i = 0; i < jobs; i++ )); do
    bsdtar -xf "$work/$i/offline.db.tar.gz" -C "$work/db"
    bsdtar -xf "$work/$i/offline.files.tar.gz" -C "$work/files"
  done
  indexed_note="with $jobs repo-add processes"
fi

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
echo "Indexed ${#packages[@]} packages $indexed_note."
