#!/bin/bash
#
# Unit tests for builder/omarchy-image-write.c, the tool that packs the root
# image into independent zstd frames (or reads the blocks of the squashfs the
# ISO ships it in) and writes it to the target with parallel O_DIRECT writes at
# install time. It is compiled here with the
# address and undefined-behaviour sanitizers, so a memory error fails the test
# even where the output happens to come out right.
#
# The synthetic image is laid out in 256 KiB frames:
#   0-3   random            4-5   zeros
#   6-9   repeating text    10    8 KiB of random (a short last frame)

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tool="$work/omarchy-image-write"
${CC:-cc} -std=gnu11 -O1 -g -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -o "$tool" "$ROOT/builder/omarchy-image-write.c" -lzstd ||
  fail "compiles" "needs a C compiler and the libzstd headers (Arch: zstd, Debian: libzstd-dev)"
pass "compiles with -Wall -Wextra -Werror and the sanitizers"

frame=$((256 * 1024))
raw="$work/raw.img"
python3 - "$raw" <<'PY'
import random, sys
rng = random.Random(1)
frame = 256 * 1024
with open(sys.argv[1], "wb") as f:
    f.write(rng.randbytes(4 * frame))
    f.write(bytes(2 * frame))
    f.write((b"omarchy " * frame)[:4 * frame])
    f.write(rng.randbytes(8192))
PY
raw_size=$(stat -c %s "$raw")

# A target of the image's size (or bigger), filled with $2.
target() {
  python3 -c 'import sys; open(sys.argv[1], "wb").write(bytes([int(sys.argv[3])]) * int(sys.argv[2]))' \
    "$1" "${3:-$raw_size}" "$2"
}

# Run the tool, capturing its exit status and stderr without tripping set -e.
run() {
  status=0
  "$tool" "$@" 2>"$work/stderr" || status=$?
}

# --- pack ------------------------------------------------------------------

image="$work/image.zst"
run pack "$raw" "$image"
[[ $status == 0 ]] || fail "pack succeeds" "$(cat "$work/stderr")"
read -r frames skips < <(zstd -l "$image" | awk 'NR == 2 { print $1, $2 }')
# zstd -l counts the skippable seek table frame among the frames.
[[ $frames == 12 && $skips == 1 ]] ||
  fail "pack writes one frame per 256 KiB and a seek table" "zstd -l counts $frames frames, $skips skippable; want 12, 1"
pass "pack writes one frame per 256 KiB and a seek table"

# The seek table read by an independent parser of the seekable format: every
# entry must point at a frame that decodes to exactly the raw bytes it claims.
python3 - "$image" "$raw" <<'PY' || fail "the seek table describes the frames"
import struct, subprocess, sys
data, raw = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
frames, descriptor, magic = struct.unpack("<IBI", data[-9:])
assert magic == 0x8F92EAB1 and descriptor == 0, (hex(magic), descriptor)
table = len(data) - 9 - 8 * frames - 8
skip_magic, skip_size = struct.unpack("<II", data[table:table + 8])
assert skip_magic == 0x184D2A5E and skip_size == 8 * frames + 9
src = dst = 0
for i in range(frames):
    c, d = struct.unpack("<II", data[table + 8 + 8 * i:table + 16 + 8 * i])
    out = subprocess.run(["zstd", "-q", "-d", "-c"], input=data[src:src + c], capture_output=True, check=True).stdout
    assert out == raw[dst:dst + d], f"frame {i}"
    src, dst = src + c, dst + d
assert src == table and dst == len(raw)
PY
pass "the seek table describes the frames, checked by an independent parser"

zstd -q -t "$image" || fail "the packed image passes zstd -t"
zstd -q -dc "$image" | cmp -s - "$raw" || fail "stock zstd -d reads the packed image back to the raw image"
pass "stock zstd -d reads the packed image back to the raw image"

printf 'x' >>"$work/odd.img"
cat "$raw" >>"$work/odd.img"
run pack "$work/odd.img" "$work/odd.zst"
[[ $status == 1 ]] || fail "pack refuses an image that is not a multiple of 4096 bytes" "status $status"
pass "pack refuses an image that is not a multiple of 4096 bytes"

# --- write -----------------------------------------------------------------

for threads in 1 3 8; do
  target "$work/target" 0
  run write "$image" "$work/target" "$threads"
  [[ $status == 0 ]] || fail "write with $threads threads succeeds" "$(cat "$work/stderr")"
  cmp -s "$work/target" "$raw" || fail "write with $threads threads reproduces the raw image"
  pass "write with $threads threads reproduces the raw image"
done

grep -q "(11 frames, 2 zero, 11 cached, 8 threads)" "$work/stderr" ||
  fail "write reports what it did" "$(cat "$work/stderr")"
pass "write reports what it did"

# The split the installer log keeps: wall time by stage, and the workers'
# thread-seconds by activity, which cannot add up to more than the threads had.
python3 - "$work/stderr" <<'PY' || fail "write reports where its time went" "$(cat "$work/stderr")"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"setup ([\d.]+) s, frames ([\d.]+) s \([\d.]+ GiB/s\), fsync ([\d.]+) s; "
              r"thread-seconds decoding ([\d.]+), writing ([\d.]+), skipping ([\d.]+), of ([\d.]+)$", text, re.M)
assert m, "no timing line"
decoding, writing, skipping, available = map(float, m.groups()[3:])
assert decoding + writing + skipping <= available + 0.02, m.group(0)
PY
pass "write reports where its time went"

# Frames whose bytes the page cache holds are written first, the rest after.
# The order must never change what lands on the target, and the count must
# follow the cache. On a disk-backed directory: tmpfs pages cannot be dropped.
disk=$(mktemp -d -p /var/tmp)
trap 'rm -rf "$work" "$disk"' EXIT
cp "$image" "$disk/image.zst"
cache() {
  python3 - "$disk/image.zst" "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.fsync(fd)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
size = os.fstat(fd).st_size
keep = {"none": 0, "half": size // 2, "all": size}[sys.argv[2]]
os.pread(fd, keep, size - keep) if keep else None
PY
}
for state in none half all; do
  cache "$state"
  target "$work/target" 0
  run write "$disk/image.zst" "$work/target" 3
  [[ $status == 0 ]] || fail "write with $state of the image cached succeeds" "$(cat "$work/stderr")"
  cmp -s "$work/target" "$raw" || fail "write with $state of the image cached reproduces the raw image"
  cached=$(sed -n 's/.* \([0-9]*\) cached,.*/\1/p' "$work/stderr")
  case $state in
    none) ok=$((cached == 0)) ;;
    half) ok=$((cached > 0 && cached < 11)) ;;
    all) ok=$((cached == 11)) ;;
  esac
  ((ok)) || fail "with $state of the image cached, write counts $cached frames as cached" "$(cat "$work/stderr")"
  pass "with $state of the image cached, write reproduces the image and counts $cached cached"
done

# Frames 4-5 decode to zeros and are never written, like dd conv=sparse:
# whatever the target held there survives. Everything else must match.
target "$work/target" 255
run write "$image" "$work/target"
[[ $status == 0 ]] || fail "write over a non-zero target succeeds" "$(cat "$work/stderr")"
cmp -s -n $((4 * frame)) "$work/target" "$raw" ||
  fail "frames before the zero frames are written"
cmp -s -i $((6 * frame)) "$work/target" "$raw" ||
  fail "frames after the zero frames are written"
[[ $(head -c $((6 * frame)) "$work/target" | tail -c $((2 * frame)) | tr -d '\377' | wc -c) == 0 ]] ||
  fail "all-zero frames are skipped, not written"
pass "all-zero frames are skipped, every other frame is written"

target "$work/big" 0 $((raw_size + 3 * frame))
run write "$image" "$work/big"
[[ $status == 0 ]] || fail "write to a target bigger than the image succeeds" "$(cat "$work/stderr")"
cmp -s -n "$raw_size" "$work/big" "$raw" || fail "write to a bigger target puts the image at its start"
pass "write to a bigger target puts the image at its start"

# --- refusals: the target untouched ---------------------------------------

# $1: expected status (2 for an image this tool does not write, so the caller
# can fall back to the pipe; 1 for a target it cannot use).
untouched() {
  local want="$1"
  local description="$2"
  local file="$3"

  [[ $status == "$want" ]] || fail "$description" "exit status $status, want $want: $(cat "$work/stderr")"
  [[ $(od -An -tx1 -v "$file" | tr -d ' \n' | tr -d 'a') == "" ]] ||
    fail "$description" "the target was modified"
  pass "$description"
}

# A copy of the packed image with bytes at $2 (negative: from the end)
# replaced by the little-endian 32-bit value $3.
patched() {
  python3 - "$image" "$1" "$2" "$3" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
at = int(sys.argv[3]) % len(data)
data[at:at + 4] = struct.pack("<I", int(sys.argv[4]))
open(sys.argv[2], "wb").write(data)
PY
}
table=$(( $(stat -c %s "$image") - 9 - 8 * 11 - 8 ))

zstd -q -c <"$raw" >"$work/plain.zst"
target "$work/target" 170
run write "$work/plain.zst" "$work/target"
untouched 2 "refuses a .zst without a seek table" "$work/target"
grep -q "no seek table" "$work/stderr" || fail "says why it refused a plain .zst" "$(cat "$work/stderr")"

head -c $(( $(stat -c %s "$image") - 100 )) "$image" >"$work/truncated.zst"
target "$work/target" 170
run write "$work/truncated.zst" "$work/target"
untouched 2 "refuses a truncated image" "$work/target"

# Frame 0's compressed size one byte short: the frames no longer cover the
# file up to the table.
first=$(python3 -c 'import struct,sys; print(struct.unpack("<I", open(sys.argv[1],"rb").read()[int(sys.argv[2]) + 8:][:4])[0])' "$image" "$table")
patched "$work/short.zst" $((table + 8)) $((first - 1))
target "$work/target" 170
run write "$work/short.zst" "$work/target"
untouched 2 "refuses a seek table whose frames do not cover the file" "$work/target"

patched "$work/unaligned.zst" $((table + 12)) 1000
target "$work/target" 170
run write "$work/unaligned.zst" "$work/target"
untouched 2 "refuses a frame size O_DIRECT cannot write" "$work/target"

patched "$work/checksummed.zst" -5 $((0x80 | 0xB1 << 8 | 0xEA << 16 | 0x92 << 24))
target "$work/target" 170
run write "$work/checksummed.zst" "$work/target"
untouched 2 "refuses a seek table descriptor it does not know" "$work/target"

target "$work/target" 170
run write "$work/missing.zst" "$work/target"
untouched 2 "refuses a missing image" "$work/target"

target "$work/small" 170 $((raw_size - 4096))
run write "$image" "$work/small"
untouched 1 "fails on a target smaller than the image, without writing" "$work/small"

run write "$image" "$work/missing-target"
[[ $status == 1 && ! -e $work/missing-target ]] || fail "fails on a missing target without creating it" "status $status"
pass "fails on a missing target without creating it"

for args in "" "write" "write $image" "write $image $work/target 0" "write $image $work/target 65" "write $image $work/target 4x" "write $image $work/target 4294967297" "unpack $raw $image"; do
  # shellcheck disable=SC2086
  run $args
  [[ $status == 2 ]] || fail "refuses bad arguments: '$args'" "status $status"
done
pass "refuses bad arguments"

# --- corruption while writing: exit 1 ---------------------------------------

# Flip a byte inside frame 0. It is random data, which zstd stores as is, so
# the frame still parses and decodes, and only its checksum can tell.
cp "$image" "$work/corrupt.zst"
offset=1000
printf '\xff' | dd of="$work/corrupt.zst" bs=1 seek="$offset" conv=notrunc status=none
target "$work/target" 0
run write "$work/corrupt.zst" "$work/target"
[[ $status == 1 ]] || fail "a corrupt frame fails the write with status 1" "status $status: $(cat "$work/stderr")"
grep -q "frame 0:" "$work/stderr" || fail "names the corrupt frame" "$(cat "$work/stderr")"
pass "a corrupt frame fails the write with status 1 and names the frame"

# A table that adds up but lies: frame 0 one byte shorter, frame 1 one longer.
# It passes every check on the table, and frame 0 then fails to decode.
second=$(python3 -c 'import struct,sys; print(struct.unpack("<I", open(sys.argv[1],"rb").read()[int(sys.argv[2]) + 16:][:4])[0])' "$image" "$table")
patched "$work/shifted.zst" $((table + 8)) $((first - 1))
python3 - "$work/shifted.zst" $((table + 16)) $((second + 1)) <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
data[int(sys.argv[2]):int(sys.argv[2]) + 4] = struct.pack("<I", int(sys.argv[3]))
open(sys.argv[1], "wb").write(data)
PY
# One thread, so frame 0 is decoded first and is the one reported.
target "$work/target" 0
run write "$work/shifted.zst" "$work/target" 1
[[ $status == 1 ]] || fail "a seek table that disagrees with its frames fails the write" "status $status: $(cat "$work/stderr")"
grep -q "frame 0:" "$work/stderr" || fail "names the frame the table misplaced" "$(cat "$work/stderr")"
pass "a seek table that disagrees with its frames fails the write and names the frame"

# A zero frame is skipped only when its bytes are exactly zstd's encoding of
# zeros. Frame 4 with one byte of its checksum changed is no longer that, so
# it is decoded, and the checksum stops the write.
zero_end=$(python3 -c '
import struct, sys
data = open(sys.argv[1], "rb").read()
table = int(sys.argv[2])
print(sum(struct.unpack("<I", data[table + 8 + 8 * i:table + 12 + 8 * i])[0] for i in range(5)))' "$image" "$table")
cp "$image" "$work/zero-altered.zst"
printf '\x00' | dd of="$work/zero-altered.zst" bs=1 seek=$((zero_end - 1)) conv=notrunc status=none
cmp -s "$image" "$work/zero-altered.zst" && { printf '\x01' | dd of="$work/zero-altered.zst" bs=1 seek=$((zero_end - 1)) conv=notrunc status=none; }
target "$work/target" 0
run write "$work/zero-altered.zst" "$work/target" 1
[[ $status == 1 ]] || fail "a zero frame that is not byte-identical is decoded, not skipped" "status $status: $(cat "$work/stderr")"
grep -q "frame 4:" "$work/stderr" || fail "names the altered zero frame" "$(cat "$work/stderr")"
pass "a zero frame that is not byte-identical is decoded, not skipped"

# --- write-squashfs -------------------------------------------------------
# The raw image as the ISO ships it: the one file of a squashfs. With 256 KiB
# blocks each frame of the synthetic image is one block: 0-3 random, which
# mksquashfs stores uncompressed; 4-5 zeros, which it does not store at all
# (sparse); 6-9 text, compressed; 10 the short last block, which
# -no-fragments keeps a block.

command -v mksquashfs >/dev/null || fail "write-squashfs tests need mksquashfs (squashfs-tools)"
squashfs() { # output, mksquashfs options
  local out="$1" dir
  shift
  dir=$(mktemp -d -p "$work")
  cp "$raw" "$dir/omarchy-root.img"
  mksquashfs "$dir" "$out" -noappend -no-xattrs -quiet -no-progress "$@" >/dev/null
}
sfs="$work/image.sfs"
squashfs "$sfs" -comp zstd -b 256K -no-fragments

for threads in 1 3 8; do
  target "$work/target" 0
  run write-squashfs "$sfs" "$work/target" "$threads"
  [[ $status == 0 ]] || fail "write-squashfs with $threads threads succeeds" "$(cat "$work/stderr")"
  cmp -s "$work/target" "$raw" || fail "write-squashfs with $threads threads reproduces the raw image"
  pass "write-squashfs with $threads threads reproduces the raw image"
done

grep -q "(11 frames, 2 zero, .* cached, 8 threads)" "$work/stderr" ||
  fail "write-squashfs reports what it did" "$(cat "$work/stderr")"
pass "write-squashfs reports what it did"

# The cache is the container's again: with all of it cached, every frame
# counts as cached.
cp "$sfs" "$disk/image.sfs"
cat "$disk/image.sfs" >/dev/null
target "$work/target" 0
run write-squashfs "$disk/image.sfs" "$work/target" 3
[[ $status == 0 ]] && grep -q "(11 frames, 2 zero, 11 cached, 3 threads)" "$work/stderr" ||
  fail "write-squashfs orders by what the page cache holds of the squashfs" "$(cat "$work/stderr")"
pass "write-squashfs orders by what the page cache holds of the squashfs"

# Sparse blocks are left unwritten: over a target of 170s, frames 4 and 5 keep
# the 170s and everything else is the image.
target "$work/target" 170
run write-squashfs "$sfs" "$work/target"
[[ $status == 0 ]] || fail "write-squashfs over a non-zero target succeeds" "$(cat "$work/stderr")"
python3 - "$work/target" "$raw" <<'PY' || fail "write-squashfs leaves the zero blocks unwritten"
import sys
frame = 256 * 1024
target, raw = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
assert target[4 * frame:6 * frame] == bytes([170]) * 2 * frame
assert target[:4 * frame] == raw[:4 * frame] and target[6 * frame:] == raw[6 * frame:]
PY
pass "write-squashfs leaves the zero blocks unwritten"

# Squashfs it does not write, refused untouched so the installer mounts it
# and uses dd instead.
# mksquashfs packs a tail into a fragment only when told to.
squashfs "$work/fragment.sfs" -comp zstd -b 256K -always-use-fragments
target "$work/target" 170
run write-squashfs "$work/fragment.sfs" "$work/target"
untouched 2 "write-squashfs refuses a file that ends in a fragment" "$work/target"
grep -q "no-fragments" "$work/stderr" || fail "says to build it with -no-fragments" "$(cat "$work/stderr")"

squashfs "$work/gzip.sfs" -comp gzip -b 256K -no-fragments
target "$work/target" 170
run write-squashfs "$work/gzip.sfs" "$work/target"
untouched 2 "write-squashfs refuses a squashfs not compressed with zstd" "$work/target"

two=$(mktemp -d -p "$work")
cp "$raw" "$two/omarchy-root.img"
cp "$raw" "$two/other.img"
mksquashfs "$two" "$work/two.sfs" -noappend -no-xattrs -quiet -no-progress -comp zstd -b 256K -no-fragments >/dev/null
target "$work/target" 170
run write-squashfs "$work/two.sfs" "$work/target"
untouched 2 "write-squashfs refuses a squashfs of more than one file" "$work/target"

target "$work/target" 170
run write-squashfs "$image" "$work/target"
untouched 2 "write-squashfs refuses a file that is not a squashfs" "$work/target"

head -c $(( $(stat -c %s "$sfs") - 4096 )) "$sfs" >"$work/truncated.sfs"
target "$work/target" 170
run write-squashfs "$work/truncated.sfs" "$work/target"
untouched 2 "write-squashfs refuses a truncated squashfs" "$work/target"

run write-squashfs "$work/missing.sfs" "$work/target"
untouched 2 "write-squashfs refuses a missing image" "$work/target"

# An inode that lies about where its blocks are or how big the file is.
# Built with -noI, so the inode table is stored as it is and the file's
# inode can be patched in place: from a copy whose zeros are holes, so that
# mksquashfs writes the extended inode (type 9) with 64-bit fields, as it
# does for the root image.
holes=$(mktemp -d -p "$work")
cp --sparse=always "$raw" "$holes/omarchy-root.img"
mksquashfs "$holes" "$work/plain-inodes.sfs" -noappend -no-xattrs -quiet -no-progress \
  -comp zstd -b 256K -no-fragments -noI >/dev/null
lying_inode() { # output, field offset in the inode, little-endian u64 value
  python3 - "$work/plain-inodes.sfs" "$@" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
table = struct.unpack_from("<Q", data, 64)[0]
inode = table + 2  # past the metadata block's header
assert struct.unpack_from("<H", data, table)[0] & 0x8000, "inode table is not stored"
assert struct.unpack_from("<H", data, inode)[0] == 9, "not an extended file inode"
struct.pack_into("<Q", data, inode + int(sys.argv[3]), int(sys.argv[4], 0))
open(sys.argv[2], "wb").write(data)
PY
}
target "$work/target" 0
run write-squashfs "$work/plain-inodes.sfs" "$work/target"
[[ $status == 0 ]] && cmp -s "$work/target" "$raw" || fail "write-squashfs writes a squashfs with stored inodes" "$(cat "$work/stderr")"
lying_inode "$work/wrapped-start.sfs" 16 0xfffffffffffff000
target "$work/target" 170
run write-squashfs "$work/wrapped-start.sfs" "$work/target"
untouched 2 "write-squashfs refuses blocks that start outside the data" "$work/target"
lying_inode "$work/wrapped-size.sfs" 24 0xfffffffffffff000
target "$work/target" 170
run write-squashfs "$work/wrapped-size.sfs" "$work/target"
untouched 2 "write-squashfs refuses a file size beyond off_t" "$work/target"

target "$work/small" 170 $((raw_size - 4096))
run write-squashfs "$sfs" "$work/small"
untouched 1 "write-squashfs fails on a target smaller than the image, without writing" "$work/small"

for args in "write-squashfs" "write-squashfs $sfs" "write-squashfs $sfs $work/target 0"; do
  # shellcheck disable=SC2086
  run $args
  [[ $status == 2 ]] || fail "write-squashfs refuses bad arguments: '$args'" "status $status"
done
pass "write-squashfs refuses bad arguments"

# The first compressed block (frame 6, the text) with its zstd magic broken
# fails the write with status 1 and names the frame. Data blocks start right
# after the 96-byte superblock; frames 0-3 are stored, 256 KiB each, and 4-5
# take no space.
start=$((96 + 4 * frame))
[[ $(od -An -tx1 -j "$start" -N 4 "$sfs" | tr -d ' ') == 28b52ffd ]] ||
  fail "the test squashfs has its first compressed block where expected" "$(od -An -tx1 -j "$start" -N 4 "$sfs")"
cp "$sfs" "$work/corrupt.sfs"
printf '\xff' | dd of="$work/corrupt.sfs" bs=1 seek="$start" conv=notrunc status=none
target "$work/target" 0
run write-squashfs "$work/corrupt.sfs" "$work/target" 1
[[ $status == 1 ]] || fail "a corrupt squashfs block fails the write with status 1" "status $status: $(cat "$work/stderr")"
grep -q "frame 6:" "$work/stderr" || fail "names the corrupt block" "$(cat "$work/stderr")"
pass "a corrupt squashfs block fails the write with status 1 and names the frame"
