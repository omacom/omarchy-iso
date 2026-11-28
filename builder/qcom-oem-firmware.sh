#!/bin/bash

# The Snapdragon OEM firmware packages in the given sync databases: every
# package that provides a qcom-firmware-<folder> name, one per firmware folder
# a device tree loads from. Omarchy's install/hardware/qualcomm/oem-firmware.sh
# installs a machine's package by that name, so the offline mirror needs all of
# them, and finding them by what they provide keeps their names out of every
# package list.
qcom_oem_firmware_packages() {
  local db
  for db in "$@"; do
    bsdtar -xOf "$db" '*/desc'
  done | awk '
    /^%NAME%$/ { getline name }
    /^%PROVIDES%$/ {
      while ((getline line) > 0 && line != "")
        if (line ~ /^qcom-firmware-/) print name
    }
  ' | sort -u
}

# Copy any qcom-firmware-extract/provided.d/*.list files shipped by the
# resolved Snapdragon OEM firmware packages into the live ISO. Only packages
# the install itself will bring are passed here, so provided.d cannot hide
# firmware for a package the install omits and huge linux-firmware-* archives
# are never scanned.
stage_live_qcom_provided_lists() {
  local target_airootfs=$1
  shift
  (( $# > 0 )) || return 0

  # Single streaming decompression pass per package in parallel across cores.
  python3 - "$target_airootfs" "$@" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import os, re, subprocess, sys, tarfile

target = sys.argv[1]
pkgs = sys.argv[2:]
PREFIX = "usr/share/qcom-firmware-extract/provided.d/"
PATTERN = re.compile(r"^usr/share/qcom-firmware-extract/provided\.d/[^/]+\.list$")

def scan_one(pkg):
    found = []
    proc = subprocess.Popen(
        ["bsdtar", "-cf", "-", f"@{pkg}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
                for member in tf:
                    name = member.name.lstrip("./")
                    if member.isfile() and PATTERN.match(name):
                        f = tf.extractfile(member)
                        if f is not None:
                            found.append((name[len(PREFIX):], f.read(), member.mode))
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
    return found

workers = min(len(pkgs), max(1, os.cpu_count() or 1))
with ThreadPoolExecutor(max_workers=workers) as pool:
    results = list(pool.map(scan_one, pkgs))

dst_dir = os.path.join(target, PREFIX.rstrip("/"))
for found in results:
    for rel, data, mode in found:
        os.makedirs(dst_dir, exist_ok=True)
        out = os.path.join(dst_dir, rel)
        with open(out, "wb") as f:
            f.write(data)
        os.chmod(out, mode & 0o777)
PY
}
