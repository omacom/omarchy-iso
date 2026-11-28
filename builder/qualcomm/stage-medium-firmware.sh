#!/usr/bin/env bash
#
# Usage: stage-medium-firmware.sh [--trees PACKAGE]... KERNEL-PACKAGE OUTPUT-DIR FIRMWARE-PACKAGE...
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
while [[ ${1:-} == --trees ]]; do
  tree_packages+=("$2")
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
  # Extract wanted firmware files in a single streaming decompression pass per
  # package across all cores, staging into per-package dirs and merging in
  # argument order so overlapping paths keep deterministic precedence.
  python3 - "$work/wanted" "$work" "$out" "$@" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import os, shutil, subprocess, sys, tarfile

wanted_path, work_dir, out_dir = sys.argv[1:4]
pkgs = sys.argv[4:]
PREFIX = "usr/lib/firmware/"

wanted = set()
with open(wanted_path, "r", encoding="utf-8") as f:
    for line in f:
        fw = line.strip()
        if not fw:
            continue
        wanted.add(PREFIX + fw)
        wanted.add(PREFIX + fw + ".xz")
        wanted.add(PREFIX + fw + ".zst")

if not wanted:
    sys.exit(0)

def extract_one(item):
    idx, pkg = item
    pkg_dir = os.path.join(work_dir, f"pkg.{idx}")
    os.makedirs(pkg_dir, exist_ok=True)
    proc = subprocess.Popen(
        ["bsdtar", "-cf", "-", f"@{pkg}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    matched = False
    fallback_hardlinks = []
    try:
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
                for member in tf:
                    name = member.name.lstrip("./")
                    if name not in wanted:
                        continue
                    rel = name[len(PREFIX):]
                    dst = os.path.join(pkg_dir, rel)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    if member.issym():
                        if os.path.lexists(dst):
                            os.unlink(dst)
                        os.symlink(member.linkname, dst)
                        matched = True
                    elif member.islnk():
                        target_name = member.linkname.lstrip("./")
                        if target_name.startswith(PREFIX):
                            target_path = os.path.join(pkg_dir, target_name[len(PREFIX):])
                            if os.path.isfile(target_path):
                                if os.path.lexists(dst):
                                    os.unlink(dst)
                                shutil.copy2(target_path, dst)
                                matched = True
                                continue
                        # Hardlink points to a member outside wanted; resolve via bsdtar below.
                        fallback_hardlinks.append((member.name, member.linkname))
                    elif member.isfile():
                        src_f = tf.extractfile(member)
                        if src_f is not None:
                            with open(dst, "wb") as out_f:
                                shutil.copyfileobj(src_f, out_f, 262144)
                            os.chmod(dst, member.mode & 0o777)
                            matched = True
        finally:
            if proc.stdout:
                proc.stdout.close()
    except tarfile.TarError as exc:
        proc.kill()
        if proc.stderr:
            proc.stderr.close()
        proc.wait()
        raise RuntimeError(f"failed to read {pkg}: {exc}") from exc
    stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
    if proc.stderr:
        proc.stderr.close()
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"bsdtar failed on {pkg} (rc={rc}): {stderr.strip()}")

    if fallback_hardlinks:
        # Extract the referenced target(s) in one pass and copy to each wanted link path.
        target_names = sorted({t for _, t in fallback_hardlinks})
        hl_dir = os.path.join(work_dir, f"hl.{idx}")
        os.makedirs(hl_dir, exist_ok=True)
        subprocess.run(["bsdtar", "-xf", pkg, "-C", hl_dir] + target_names, check=True)
        for member_name, linkname in fallback_hardlinks:
            src_t = os.path.join(hl_dir, linkname.lstrip("./"))
            rel = member_name.lstrip("./")[len(PREFIX):]
            dst = os.path.join(pkg_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.lexists(dst):
                os.unlink(dst)
            shutil.copy2(src_t, dst)
            matched = True
        shutil.rmtree(hl_dir, ignore_errors=True)

    return pkg_dir if matched else None

workers = min(len(pkgs), max(1, os.cpu_count() or 1))
with ThreadPoolExecutor(max_workers=workers) as pool:
    pkg_dirs = list(pool.map(extract_one, enumerate(pkgs)))

for pkg_dir in pkg_dirs:
    if pkg_dir is None:
        continue
    for dirpath, _, filenames in os.walk(pkg_dir):
        rel_dir = os.path.relpath(dirpath, pkg_dir)
        dst_dir = out_dir if rel_dir == "." else os.path.join(out_dir, rel_dir)
        os.makedirs(dst_dir, exist_ok=True)
        for fn in filenames:
            src_p = os.path.join(dirpath, fn)
            dst_p = os.path.join(dst_dir, fn)
            if os.path.lexists(dst_p):
                os.unlink(dst_p)
            shutil.move(src_p, dst_p)
PY
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
