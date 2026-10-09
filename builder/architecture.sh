#!/bin/bash
# shellcheck disable=SC2034

# Shared by the host launcher and the build container. Keep the existing
# Snapdragon image as the ARM default; generic media uses firmware tables.
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
  x86_64:x86_64/pc|aarch64:aarch64/snapdragon|aarch64:aarch64/generic) ;;
  *)
    echo "Unsupported architecture/media target: $OMARCHY_ARCH:$OMARCHY_MEDIA_TARGET" >&2
    return 1
    ;;
esac

ISO_ARCH=$OMARCHY_ARCH
OMARCHY_ISO_NAME=omarchy
if [[ $OMARCHY_MEDIA_TARGET == aarch64/generic ]]; then
  OMARCHY_ISO_NAME=omarchy-generic
fi
export OMARCHY_ARCH OMARCHY_MEDIA_TARGET OMARCHY_ISO_NAME
