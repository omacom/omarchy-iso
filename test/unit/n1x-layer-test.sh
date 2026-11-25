#!/bin/bash
#
# The N1x layer (builder/build-root-image.sh write_layer) is the overlay's
# upper directory after the NVIDIA stack is pacstrapped over the image, packed
# for the installer to extract over the written image
# (phases_impl._apply_platform_layer). It must carry the packages, their pacman
# database entries and what their hooks left, and none of the paths the target
# makes or owns for itself.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$ROOT/builder/build-root-image.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$(sed -n '/^layer_path() {$/,/^}$/p' "$builder")"
eval "$(sed -n '/^write_layer() {$/,/^}$/p' "$builder")"
declare -F write_layer >/dev/null || fail "the builder has no write_layer"

# The layer sits next to the root image, under the name the installer looks
# for: omarchy-layer.<hw_platform>.tar.zst.
output="$work/iso/omarchy-root.img.zst"
mkdir -p "$work/iso"
[[ $(layer_path aarch64-n1x) == "$work/iso/omarchy-layer.aarch64-n1x.tar.zst" ]] || fail "layer path: $(layer_path aarch64-n1x)"
echo "ok - the N1x layer is written next to the root image as omarchy-layer.aarch64-n1x.tar.zst"

upper="$work/upper"
mkdir -p "$upper/usr/lib/modules/7.3.0-62-omarchy/extramodules" "$upper/var/lib/pacman/local/nvidia-utils-615.78.08-3" \
  "$upper/etc" "$upper/boot/EFI/Linux" "$upper/var/cache/pacman/pkg" "$upper/var/log" "$upper/var/lib/pacman/sync" \
  "$upper/etc/pacman.d/gnupg" "$upper/tmp" "$upper/run"
echo module >"$upper/usr/lib/modules/7.3.0-62-omarchy/extramodules/nvidia.ko.zst"
echo index >"$upper/usr/lib/modules/7.3.0-62-omarchy/modules.dep"
echo desc >"$upper/var/lib/pacman/local/nvidia-utils-615.78.08-3/desc"
echo cache >"$upper/etc/ld.so.cache"
echo 'nvidia-persistenced:x:143:143::/:/usr/bin/nologin' >"$upper/etc/passwd"
echo uki >"$upper/boot/EFI/Linux/omarchy_linux-omarchy.efi"
echo pkg >"$upper/var/cache/pacman/pkg/nvidia-utils.pkg.tar.zst"
echo log >"$upper/var/log/pacman.log"
echo db >"$upper/var/lib/pacman/sync/extra.db"
echo key >"$upper/etc/pacman.d/gnupg/pubring.gpg"
echo tmp >"$upper/tmp/scratch"

write_layer "$upper" aarch64-n1x >/dev/null || fail "write_layer failed on a plain upper directory"
layer=$(layer_path aarch64-n1x)
[[ -s $layer ]] || fail "no layer written"

listing=$(tar --zstd -tf "$layer")
for kept in ./usr/lib/modules/7.3.0-62-omarchy/extramodules/nvidia.ko.zst ./usr/lib/modules/7.3.0-62-omarchy/modules.dep \
  ./var/lib/pacman/local/nvidia-utils-615.78.08-3/desc ./etc/ld.so.cache ./etc/passwd; do
  grep -qxF "$kept" <<<"$listing" || fail "the layer lacks $kept"
done
echo "ok - the layer carries the packages, their database entries, the module index, linker cache and users"

for left in ./boot ./var/cache ./var/log ./var/lib/pacman/sync ./etc/pacman.d/gnupg ./tmp ./run; do
  if grep -q "^${left}\(/\|$\)" <<<"$listing"; then fail "the layer carries $left"; fi
done
echo "ok - the layer leaves out the ESP, caches, logs, sync databases, the keyring and mount points"

# Extracted the way the installer does, over a root whose /lib is the usrmerge
# symlink, the files land and the symlink stays one.
target="$work/target"
mkdir -p "$target/usr/lib" "$target/etc"
ln -s usr/lib "$target/lib"
echo image-passwd >"$target/etc/passwd"
tar --zstd -xpf "$layer" -C "$target" --numeric-owner --acls --xattrs --xattrs-include='*' --keep-directory-symlink
[[ -L $target/lib ]] || fail "extraction replaced the /lib symlink"
[[ $(<"$target/usr/lib/modules/7.3.0-62-omarchy/extramodules/nvidia.ko.zst") == module ]] || fail "module not extracted"
grep -q nvidia-persistenced "$target/etc/passwd" || fail "the layer's /etc/passwd did not replace the image's"
echo "ok - the installer's extraction lands the layer over the image"

# A whiteout means the pacstrap deleted something from the image, which a
# tarball cannot express. Making one needs root.
if ((EUID == 0)); then
  mknod "$upper/usr/lib/removed" c 0 0
  if write_layer "$upper" aarch64-n1x >/dev/null 2>"$work/err"; then fail "a layer with a whiteout was packed"; fi
  grep -q "deletes files" "$work/err" || fail "the refusal does not say why: $(cat "$work/err")"
  echo "ok - an upper directory with a whiteout is refused"
fi
