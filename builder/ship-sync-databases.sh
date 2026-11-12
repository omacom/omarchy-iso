#!/bin/bash
#
# Give the root image the package indexes of the repositories the installed
# system uses.
#
# pacstrap syncs only the repositories of the config it is given, and the image
# is pacstrapped from the offline mirror, so on its own the image's sync
# directory holds offline.db and nothing else. The installed system's
# pacman.conf names [core], [extra], [omarchy] and the rest, and with no index
# for any of them every `pacman -S` fails with "target not found" until the
# first -Syu. First run only offers that update when something is out of date,
# and on current media nothing is, so the machine cannot install software until
# its owner thinks of updating by hand.
#
# The indexes come from the build's own sync, the one every package in the
# offline mirror was downloaded against, so they describe exactly the versions
# the image holds: installing more needs no partial upgrade. Only the
# repositories the image's runtime can configure are shipped: its pacman.conf
# templates, plus the repositories its hardware scripts add (arch-mact2 on a T2
# Mac). Build-only repositories such as aarch64's file:// [platform] bundle stay
# behind. offline.db stays too: the installer runs the target's own pacman
# against the offline config until the final pacman.conf restore.
#
# Usage: ship-sync-databases.sh <image-root> <build-sync-dir>

set -euo pipefail

root="${1:-}" source_dir="${2:-}"
if [[ -z $root || -z $source_dir ]]; then
  echo "Usage: ship-sync-databases.sh <image-root> <build-sync-dir>" >&2
  exit 1
fi

runtime="$root/usr/share/omarchy"
mapfile -t repos < <(
  {
    find "$runtime/default/pacman" -name 'pacman-*.conf' -print0 2>/dev/null | xargs -0r cat
    cat "$runtime/install/hardware/pacman.sh" 2>/dev/null || true
  } | sed -n 's/^\[\([^]]*\)\][[:space:]]*$/\1/p' | grep -vx options | sort -u
)
if (( ${#repos[@]} == 0 )); then
  echo "ERROR: no pacman.conf templates under $runtime/default/pacman" >&2
  exit 1
fi

sync_dir="$root/var/lib/pacman/sync"
mkdir -p "$sync_dir"
shipped=()
for repo in "${repos[@]}"; do
  # A repository only one platform or one machine uses (multilib on x86,
  # alarm on ARM, arch-mact2) has no index in another build's sync.
  [[ -f $source_dir/$repo.db ]] || continue
  # -p keeps the mtime pacman compares against the server's on the next -Sy.
  cp -p "$source_dir/$repo.db" "$sync_dir/$repo.db"
  shipped+=("$repo")
done

for required in core extra omarchy; do
  if [[ ! -f $sync_dir/$required.db ]]; then
    echo "ERROR: no $required.db in $source_dir to ship in the image" >&2
    exit 1
  fi
done

echo "Shipping package indexes in the image: ${shipped[*]}"
