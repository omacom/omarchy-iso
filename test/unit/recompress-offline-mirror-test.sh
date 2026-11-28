#!/bin/bash
#
# Recompressing small-window .pkg.tar.zst packages in the staged shipped mirror
# shrinks the ISO while preserving offline.db metadata, untouched high-window
# packages, archlinuxarm-keyring signatures, and --fast build speed.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$ROOT/builder/recompress-offline-mirror.sh"
bash -n "$script"
if ! command -v repo-add >/dev/null || ! command -v zstd >/dev/null; then
  echo "recompress-offline-mirror tests skipped: missing repo-add or zstd"
  exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

make_pkg() { # out_dir name zstd_args...
  local out_dir=$1 name=$2
  shift 2
  local stage="$fixture/stage-$name"
  rm -rf "$stage"
  mkdir -p "$stage/usr/share/$name"
  # 4 MiB of repetitive-with-distance data so a 2 MiB window (level 3) misses
  # long-range matches that --ultra -22 --long=27 finds.
  python3 - "$stage/usr/share/$name/blob.bin" <<'PY'
import sys
chunk = bytes((i * 31 + (i >> 3)) & 0xFF for i in range(4096))
block = (chunk * 700)  # ~2.86 MiB
with open(sys.argv[1], "wb") as f:
    f.write(block)
    f.write(b"SEPARATOR" * 1000)
    f.write(block)
PY
  printf 'pkgname = %s\npkgver = 1.0-1\npkgdesc = fixture\narch = any\nsize = 6000000\n' "$name" >"$stage/.PKGINFO"
  bsdtar -cf - -C "$stage" .PKGINFO usr | zstd -q "$@" -o "$out_dir/$name-1.0-1-any.pkg.tar.zst"
  printf 'fake-sig\n' >"$out_dir/$name-1.0-1-any.pkg.tar.zst.sig"
}

mirror="$fixture/mirror"
mkdir -p "$mirror"
make_pkg "$mirror" lvl3 -3
make_pkg "$mirror" archlinuxarm-keyring -3
make_pkg "$mirror" already-long -19 --long=27
repo-add -q "$mirror/offline.db.tar.gz" "$mirror"/*.pkg.tar.zst >/dev/null 2>&1
rm -f "$mirror"/offline.db*.old "$mirror"/offline.files*.old

# Under OMARCHY_FAST_COMPRESSION=1, nothing is touched.
fast_copy="$fixture/fast"
cp -a "$mirror" "$fast_copy"
before_fast=$(stat -c %s "$fast_copy/lvl3-1.0-1-any.pkg.tar.zst")
OMARCHY_FAST_COMPRESSION=1 bash "$script" "$fast_copy" >/dev/null
[[ $(stat -c %s "$fast_copy/lvl3-1.0-1-any.pkg.tar.zst") == "$before_fast" ]] ||
  fail "OMARCHY_FAST_COMPRESSION=1 modified packages"
[[ -f "$fast_copy/lvl3-1.0-1-any.pkg.tar.zst.sig" ]] ||
  fail "OMARCHY_FAST_COMPRESSION=1 removed .sig"
echo "ok - OMARCHY_FAST_COMPRESSION=1 skips mirror recompression"

# Full run recompresses lvl3, drops its stale .sig, updates offline.db, leaves
# archlinuxarm-keyring (+ .sig) and already-long untouched, and leaves no .old DBs.
lvl3_before=$(stat -c %s "$mirror/lvl3-1.0-1-any.pkg.tar.zst")
keyring_sha_before=$(sha256sum "$mirror/archlinuxarm-keyring-1.0-1-any.pkg.tar.zst" | awk '{print $1}')
long_sha_before=$(sha256sum "$mirror/already-long-1.0-1-any.pkg.tar.zst" | awk '{print $1}')

OMARCHY_FAST_COMPRESSION=0 bash "$script" "$mirror" >/dev/null

lvl3_after=$(stat -c %s "$mirror/lvl3-1.0-1-any.pkg.tar.zst")
(( lvl3_after < lvl3_before )) || fail "lvl3 did not shrink ($lvl3_before -> $lvl3_after)"
[[ ! -e "$mirror/lvl3-1.0-1-any.pkg.tar.zst.sig" ]] || fail "stale .sig remained after recompression"
[[ -f "$mirror/archlinuxarm-keyring-1.0-1-any.pkg.tar.zst.sig" ]] || fail "archlinuxarm-keyring .sig was removed"
[[ $(sha256sum "$mirror/archlinuxarm-keyring-1.0-1-any.pkg.tar.zst" | awk '{print $1}') == "$keyring_sha_before" ]] ||
  fail "archlinuxarm-keyring was modified"
[[ $(sha256sum "$mirror/already-long-1.0-1-any.pkg.tar.zst" | awk '{print $1}') == "$long_sha_before" ]] ||
  fail "already-long (128 MiB window) package was modified"
[[ ! -e "$mirror/offline.db.tar.gz.old" ]] || fail "repo-add left offline.db.tar.gz.old behind"

# offline.db %CSIZE% and %SHA256SUM% must match the repacked archive, and
# untouched entries must still be present in offline.db.
db_dir="$fixture/db"
mkdir -p "$db_dir"
bsdtar -xf "$mirror/offline.db.tar.gz" -C "$db_dir"
db_csize=$(awk '/^%CSIZE%$/ { getline; print }' "$db_dir/lvl3-1.0-1/desc")
db_sha=$(awk '/^%SHA256SUM%$/ { getline; print }' "$db_dir/lvl3-1.0-1/desc")
actual_sha=$(sha256sum "$mirror/lvl3-1.0-1-any.pkg.tar.zst" | awk '{print $1}')
[[ $db_csize == "$lvl3_after" ]] || fail "offline.db CSIZE=$db_csize != actual $lvl3_after"
[[ $db_sha == "$actual_sha" ]] || fail "offline.db SHA256SUM=$db_sha != actual $actual_sha"
[[ -f "$db_dir/already-long-1.0-1/desc" && -f "$db_dir/archlinuxarm-keyring-1.0-1/desc" ]] ||
  fail "untouched packages disappeared from offline.db"
echo "ok - recompresses lvl3 packages, updates offline.db, keeps keyring sig and high-window packages"

# Parallel LPT pool with multiple candidates removes stale .sig files, updates
# offline.db deterministically, and leaves archlinuxarm-keyring untouched.
mirror_par="$fixture/mirror-par"
mkdir -p "$mirror_par"
make_pkg "$mirror_par" lvl3-a -3
make_pkg "$mirror_par" lvl3-b -3
make_pkg "$mirror_par" archlinuxarm-keyring -3
repo-add -q "$mirror_par/offline.db.tar.gz" "$mirror_par"/*.pkg.tar.zst >/dev/null 2>&1
rm -f "$mirror_par"/offline.db*.old "$mirror_par"/offline.files*.old

par_out=$(OMARCHY_FAST_COMPRESSION=0 OMARCHY_RECOMPRESS_THREADS=2 bash "$script" "$mirror_par")
grep -q "repacked 2 of 2 packages (" <<<"$par_out" ||
  fail "expected 2 of 2 repacked in parallel run, got: $par_out"
[[ ! -e "$mirror_par/lvl3-a-1.0-1-any.pkg.tar.zst.sig" && ! -e "$mirror_par/lvl3-b-1.0-1-any.pkg.tar.zst.sig" ]] ||
  fail "stale .sig remained after parallel recompression"
[[ -f "$mirror_par/archlinuxarm-keyring-1.0-1-any.pkg.tar.zst.sig" ]] ||
  fail "archlinuxarm-keyring .sig was removed in parallel run"

db_par="$fixture/db-par"
mkdir -p "$db_par"
bsdtar -xf "$mirror_par/offline.db.tar.gz" -C "$db_par"
par_db_sha=$(awk '/^%SHA256SUM%$/ { getline; print }' "$db_par/lvl3-a-1.0-1/desc")
par_actual_sha=$(sha256sum "$mirror_par/lvl3-a-1.0-1-any.pkg.tar.zst" | awk '{print $1}')
[[ $par_db_sha == "$par_actual_sha" ]] || fail "parallel offline.db SHA256SUM mismatch"
echo "ok - parallel LPT pool repacks candidates, updates offline.db, and keeps keyring sig"
