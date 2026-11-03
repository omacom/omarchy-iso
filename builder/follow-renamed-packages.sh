#!/bin/bash
#
# The install scripts in the root image ask pacman for packages by name on the
# hardware they match (install/hardware/apple/fix-t2.sh and friends), where no
# VM test goes, and one unknown name fails the whole `pacman -S` it shares with
# the others. build-iso.sh knows which names no repository offers any more:
#
#   renamed     "old new" per line: rewrite old to new in the install scripts
#   unresolved  one name per line, dropped from the mirror: if an install
#               script still asks for one, stop the build. Shipping it means a
#               broken install on exactly the machines nobody tested.
#
# Usage: follow-renamed-packages.sh <install-scripts-dir> <renamed> <unresolved>
# Either list may be missing or empty.

set -euo pipefail

scripts_dir="$1" renamed="$2" unresolved="$3"

# A package name as a whole word: not part of a longer name on either side.
word() {
  printf '(^|[^A-Za-z0-9@._+-])%s($|[^A-Za-z0-9@._+-])' "$(sed 's/[.+]/\\&/g' <<<"$1")"
}
asks_for() {
  grep -rlE --include='*.sh' "$(word "$1")" "$scripts_dir" 2>/dev/null || true
}

if [[ -s $renamed ]]; then
  while read -r old new; do
    while read -r script; do
      [[ -n $script ]] || continue
      sed -i -E "s/$(word "$old")/\1$new\2/g" "$script"
      bash -n "$script"
      echo "${script#"$scripts_dir"/} asks for $new instead of $old"
    done < <(asks_for "$old")
  done <"$renamed"
fi

failed=0
if [[ -s $unresolved ]]; then
  while read -r dropped; do
    scripts=$(asks_for "$dropped")
    [[ -n $scripts ]] || continue
    echo "ERROR: no repository offers '$dropped', and the install still asks for it in:" >&2
    sed "s|^$scripts_dir/|  |" <<<"$scripts" >&2
    failed=1
  done <"$unresolved"
fi
if ((failed)); then
  echo "Add the replacement to renamed_packages in builder/build-iso.sh." >&2
  exit 1
fi
