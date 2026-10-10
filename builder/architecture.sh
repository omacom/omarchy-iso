#!/bin/bash
# shellcheck disable=SC2034

# Shared by the host launcher and the build container. Keep the existing
# Snapdragon image as the ARM default; generic media uses firmware tables, and
# the N1x image carries that laptop's own kernel.
OMARCHY_ARCH=${OMARCHY_ARCH:-$(uname -m)}
[[ $OMARCHY_ARCH == arm64 ]] && OMARCHY_ARCH=aarch64
case "$OMARCHY_ARCH" in
  x86_64)
    OMARCHY_MEDIA_TARGET=${OMARCHY_MEDIA_TARGET:-x86_64/pc}
    ISO_NODE_ARCH=x64
    ISO_KERNEL=linux-t2
    BUILD_IMAGE=ghcr.io/archlinux/archlinux:latest
    DOCKER_PLATFORM=linux/amd64
    ;;
  aarch64)
    OMARCHY_MEDIA_TARGET=${OMARCHY_MEDIA_TARGET:-aarch64/snapdragon}
    ISO_NODE_ARCH=arm64
    ISO_KERNEL=linux-aarch64
    BUILD_IMAGE=menci/archlinuxarm:base-devel
    DOCKER_PLATFORM=linux/arm64
    ;;
  *)
    echo "Unsupported ISO architecture: $OMARCHY_ARCH" >&2
    return 1
    ;;
esac

case "$OMARCHY_ARCH:$OMARCHY_MEDIA_TARGET" in
  x86_64:x86_64/pc|aarch64:aarch64/snapdragon|aarch64:aarch64/generic|aarch64:aarch64/n1x) ;;
  *)
    echo "Unsupported architecture/media target: $OMARCHY_ARCH:$OMARCHY_MEDIA_TARGET" >&2
    return 1
    ;;
esac

# The hardware family the image is built for, by the name the runtime gives it
# (install/omarchy-aarch64-<family>.packages). Generic media has none.
case "$OMARCHY_MEDIA_TARGET" in
  aarch64/snapdragon)
    OMARCHY_ARM_PLATFORM=qualcomm
    ;;
  aarch64/n1x)
    OMARCHY_ARM_PLATFORM=n1x
    ISO_KERNEL=linux-omarchy-n1x
    # Pinned by digest: this container runs with the privileges archiso needs,
    # so a mutable third-party tag is not acceptable.
    BUILD_IMAGE=menci/archlinuxarm@sha256:3e1074c407fc1a57c2a2117af6920c96a7cc906fa6f1f2da8a4a7fd3aa2c2f4e
    ;;
  *)
    OMARCHY_ARM_PLATFORM=""
    ;;
esac

ISO_ARCH=$OMARCHY_ARCH
# The live kernel. An N1x image also installs it on the target.
OMARCHY_KERNEL=$ISO_KERNEL
OMARCHY_ISO_NAME=omarchy
if [[ $OMARCHY_MEDIA_TARGET == aarch64/generic ]]; then
  OMARCHY_ISO_NAME=omarchy-generic
fi
export OMARCHY_ARCH OMARCHY_MEDIA_TARGET OMARCHY_ARM_PLATFORM OMARCHY_ISO_NAME
