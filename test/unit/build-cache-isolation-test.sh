#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILDER="$ROOT/bin/omarchy-iso-make"

grep -Fq -- '--no-host-pkg-cache)' "$BUILDER"
echo "ok: isolated builds expose an explicit host-package-cache switch"

grep -Fq -- 'if [[ -z $NO_HOST_PKG_CACHE && -d /var/cache/pacman/pkg ]]; then' "$BUILDER"
echo "ok: isolated builds do not mount the host package cache"

grep -Fq -- 'if [[ -z $KEEP_PKG_CACHE && -z $NO_HOST_PKG_CACHE ]]; then' "$BUILDER"
echo "ok: isolated builds never purge a cache they do not mount"
