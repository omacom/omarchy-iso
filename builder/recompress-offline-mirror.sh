#!/bin/bash
#
# Recompress low-level zstd packages in the staged shipped offline mirror
# using heavy-CI zstd settings (--ultra -22 --long=27, 128 MiB decode window)
# so the ISO ships fewer bytes and omarchy-mirror-verify.service hashes less
# data on every boot, without modifying the persistent pacman download cache.
#
# Usage: recompress-offline-mirror.sh <staged-mirror-dir>
#
# Only packages whose zstd frame window is under 32 MiB (e.g. default level 3
# with a 2 MiB window) are recompressed; packages already packed at Arch's
# 32-128 MiB window settings are left untouched, as is archlinuxarm-keyring
# whose upstream .sig is verified at install time on aarch64. When a package
# shrinks, its now-stale .sig is removed and offline.db.tar.gz is updated via
# repo-add so %CSIZE% and %SHA256SUM% match.
#
# Skipped under OMARCHY_FAST_COMPRESSION=1 so --fast builds stay quick.

set -euo pipefail

dir="${1:-}"
if [[ ! -d $dir ]]; then
  echo "Usage: recompress-offline-mirror.sh <staged-mirror-dir>" >&2
  exit 1
fi

if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
  echo "recompress-offline-mirror: skipped under OMARCHY_FAST_COMPRESSION=1"
  exit 0
fi

# Print paths of .pkg.tar.zst candidates whose first zstd frame uses a window
# smaller than 32 MiB, skipping archlinuxarm-keyring (signed check on aarch64).
mapfile -d '' -t candidates < <(
  python3 - "$dir" <<'PY'
import os, struct, sys

mirror_dir = sys.argv[1]
WINDOW_THRESHOLD = 32 * 1024 * 1024
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"

def zstd_window_size(path):
    with open(path, "rb") as f:
        hdr = f.read(18)
    if len(hdr) < 6 or hdr[:4] != ZSTD_MAGIC:
        return None
    fhd = hdr[4]
    single_segment = (fhd >> 5) & 1
    fcs_flag = (fhd >> 6) & 3
    if not single_segment:
        wd = hdr[5]
        exponent = wd >> 3
        mantissa = wd & 7
        base = 1 << (10 + exponent)
        return base + (base // 8) * mantissa
    dict_id_flag = fhd & 3
    dict_id_len = (0, 1, 2, 4)[dict_id_flag]
    fcs_off = 5 + dict_id_len
    if fcs_flag == 0:
        return hdr[fcs_off] if len(hdr) > fcs_off else None
    if fcs_flag == 1:
        return (struct.unpack_from("<H", hdr, fcs_off)[0] + 256) if len(hdr) >= fcs_off + 2 else None
    if fcs_flag == 2:
        return struct.unpack_from("<I", hdr, fcs_off)[0] if len(hdr) >= fcs_off + 4 else None
    return struct.unpack_from("<Q", hdr, fcs_off)[0] if len(hdr) >= fcs_off + 8 else None

for name in sorted(os.listdir(mirror_dir)):
    if not name.endswith(".pkg.tar.zst"):
        continue
    if name.startswith("archlinuxarm-keyring-"):
        continue
    path = os.path.join(mirror_dir, name)
    if not os.path.isfile(path):
        continue
    win = zstd_window_size(path)
    if win is not None and win < WINDOW_THRESHOLD:
        sys.stdout.buffer.write(path.encode("utf-8") + b"\0")
PY
)

if (( ${#candidates[@]} == 0 )); then
  echo "recompress-offline-mirror: no small-window .pkg.tar.zst candidates in $dir"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-recompress.XXXXXX")
trap 'rm -rf "$work"' EXIT

repacked=()
before_bytes=0
after_bytes=0

for pkg in "${candidates[@]}"; do
  orig_size=$(stat -c %s "$pkg")
  tmp="$work/$(basename "$pkg")"
  # Decompress and recompress in a streaming pipeline so large packages never
  # materialize an uncompressed tarball on disk.
  zstd -dc "$pkg" | zstd -q -T0 --ultra -22 --long=27 -o "$tmp"
  new_size=$(stat -c %s "$tmp")
  if (( new_size < orig_size )); then
    # Replace directory entry rather than mutating in place so reflink copies
    # from the persistent download cache stay untouched.
    mv -f "$tmp" "$pkg"
    rm -f "$pkg.sig"
    repacked+=("$pkg")
    before_bytes=$((before_bytes + orig_size))
    after_bytes=$((after_bytes + new_size))
  else
    rm -f "$tmp"
  fi
done

if (( ${#repacked[@]} == 0 )); then
  echo "recompress-offline-mirror: ${#candidates[@]} candidates checked, none shrank"
  exit 0
fi

if [[ -f "$dir/offline.db.tar.gz" ]]; then
  repo-add -q "$dir/offline.db.tar.gz" "${repacked[@]}" >/dev/null
  rm -f "$dir"/offline.db*.old "$dir"/offline.files*.old
fi

saved_bytes=$((before_bytes - after_bytes))
echo "recompress-offline-mirror: repacked ${#repacked[@]} of ${#candidates[@]} packages: $((before_bytes >> 20)) MiB -> $((after_bytes >> 20)) MiB (-$((saved_bytes >> 20)) MiB)"
