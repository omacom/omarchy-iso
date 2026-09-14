#!/bin/bash
#
# Runs inside the live root while mkarchiso builds it, after the live packages
# were pacstrapped from the bundled mirror.
#
# The mirror itself is not in here any more: it ships as ordinary files in the
# ISO9660 tree beside the root image (builder/stage-mirror-files.sh) and is
# bind-mounted over this path at boot by var-cache-omarchy-mirror-offline.mount. All
# that belongs in the squashfs is the empty mount point, so this asserts
# exactly that -- a package file left here would be a second, stale copy of
# archives the image already holds, silently adding its own size to the ISO.

set -euo pipefail

mirror=/var/cache/omarchy/mirror/offline

if [[ ! -d $mirror ]]; then
  echo "ERROR: the offline mirror mount point is missing from the live root: $mirror" >&2
  echo "       The mirror image has nowhere to mount, so the install would find" >&2
  echo "       no packages at all." >&2
  exit 1
fi

# Collected whole, then trimmed for the message: piping find into head would
# SIGPIPE it, and under pipefail that failure arrives instead of the diagnosis.
mapfile -t leaked < <(find "$mirror" -mindepth 1 -printf '%P\n')
if (( ${#leaked[@]} > 0 )); then
  echo "ERROR: the offline mirror mount point is not empty in the live root:" >&2
  printf '  %s\n' "${leaked[@]:0:20}" >&2
  (( ${#leaked[@]} > 20 )) && printf '  ... and %d more\n' "$(( ${#leaked[@]} - 20 ))" >&2
  echo "       These ship inside the squashfs on top of the mirror image that" >&2
  echo "       mounts over them, so they are dead weight in the ISO." >&2
  exit 1
fi

echo "Offline mirror mount point is empty; the mirror ships as files on the ISO."
