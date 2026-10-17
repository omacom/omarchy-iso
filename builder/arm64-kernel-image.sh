#!/bin/bash

raw_arm64_image_magic() {
  dd if="$1" bs=1 skip=56 count=4 status=none | od -An -tx1 | tr -d ' \n'
}

raw_arm64_image_prefix() {
  dd if="$1" bs=1 count=2 status=none | od -An -tx1 | tr -d ' \n'
}

is_raw_arm64_kernel_image() {
  local image=$1

  # An uncompressed arm64 Image always carries the little-endian ARMd magic
  # at offset 56. With CONFIG_EFI_STUB it also legitimately starts with MZ,
  # because the same Image masquerades as a PE/COFF executable.
  [[ $(raw_arm64_image_magic "$image") == 41524d64 ]]
}
