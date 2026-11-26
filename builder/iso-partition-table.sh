#!/bin/bash

# UEFI firmware takes a GPT only behind a protective MBR: an MBR entry of type
# 0xEE that starts at LBA 1. An ISO with a GPT header and no such entry has no
# GPT to firmware. The firmware then reaches the boot files through the El
# Torito catalog alone, as a CD image, and one that offers no CD image on a
# USB disk reporting itself as fixed leaves the stick out of its boot menu: an
# MSI Z690 with a SanDisk Extreme Pro did, and listed the same stick once the
# GPT was valid (builder/archiso-valid-gpt.patch).
#
# blkid reads a GPT only behind a 0xEE entry too, and then holds the header
# and the partition entries to their checksums. For the layout without that
# entry it reports the MBR, as "dos".
iso_has_valid_gpt() {
  [[ $(blkid --probe --match-tag PTTYPE --output value "$1" 2>/dev/null) == "gpt" ]]
}
