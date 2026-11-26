#!/usr/bin/env bash

# UEFI firmware takes a GPT only behind a protective MBR: an MBR entry of type
# 0xEE that starts at LBA 1. An ISO with a GPT header and no such entry has no
# GPT to firmware. The firmware then reaches the boot files through the El
# Torito catalog alone, as a CD image, and one that offers no CD image on a
# USB disk reporting itself as fixed leaves the stick out of its boot menu: an
# MSI Z690 with a SanDisk Extreme Pro did, and listed the same stick once the
# GPT was valid (builder/archiso-valid-gpt.patch).
iso_has_valid_gpt() {
  local iso=$1 slot entry

  # Bytes as hex throughout: read as text, a sector of zeros makes bash warn
  # about every NUL it drops. 45 46 49 20 50 41 52 54 is "EFI PART".
  [[ $(od -An -tx1 -j 512 -N 8 "$iso" 2>/dev/null | tr -d ' \n') == "4546492050415254" ]] || return 1
  for slot in 0 1 2 3; do
    # One 16-byte MBR entry as hex: the type is byte 4, the first LBA bytes 8
    # to 11, little-endian.
    entry=$(od -An -tx1 -j $((446 + 16 * slot)) -N 16 "$iso" 2>/dev/null | tr -d ' \n')
    [[ ${entry:8:2} == "ee" && ${entry:16:8} == "01000000" ]] && return 0
  done
  return 1
}

# The ISO in directory $1 that was written after file $2. The build's output
# directory is the launcher's release directory, which keeps the ISOs of
# earlier builds, so the build checks only the one it wrote itself.
iso_written_since() {
  find "$1" -maxdepth 1 -name '*.iso' -newer "$2"
}
