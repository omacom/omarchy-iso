#!/bin/bash
#
# The free-space install formats inside the configurator, so the configurator
# is the only thing that can refuse a bad install medium before parted, wipefs,
# luksFormat and mkfs have already run. The full-disk path has an integration
# scenario for its gate (corrupt-image-test.sh, which autoinstalls from cidata
# and so never reaches the configurator at all); this path has none, and
# deleting its gate outright leaves ./test/all green. Assert the ordering
# statically instead: whatever else moves, both verifications -- the root image
# that lands on the disk and the offline mirror that pacstrap reads afterwards
# -- have to run before run_partition_execute.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"

# Comment lines are dropped first: the branch below is explained in prose that
# names both the helper and the function, so matching them would find the
# explanation whether or not the code still does it.
line_of() { # what, pattern, [count] -> the line number(s) matching it
  local what=$1 pattern=$2 want=${3:-1} hits
  hits=$(grep -vnE '^\s*#' "$configurator" | grep -E ":$pattern" | cut -d: -f1)
  if [[ $(grep -c . <<<"$hits") -ne $want ]]; then
    echo "expected exactly $want $what in ${configurator#"$ROOT/"}, found: ${hits:-none}" >&2
    exit 1
  fi
  printf '%s\n' "$hits"
}

branch=$(line_of "free_space branch" 'if \[\[ \$install_target == "free_space" \]\]; then$')
format=$(line_of "call to run_partition_execute" '\s+run_partition_execute ')
# Both units, each named at its own call: the mirror one is the newer of the
# two and the easier to lose in a refactor, since only the packages depend on
# it and those are read after the formatting is already done.
root_gate=$(line_of "root image gate" '.*omarchy-root-image-verify\.service')
mirror_gate=$(line_of "offline mirror gate" '.*omarchy-mirror-verify\.service')

for gate in "$root_gate" "$mirror_gate"; do
  ((branch < gate)) ||
    { echo "a verify gate is outside the free_space branch (branch $branch, gate $gate)"; exit 1; }
  ((gate < format)) ||
    { echo "run_partition_execute runs before a verify gate (gate $gate, format $format): a corrupt install medium would be found only after the disk was partitioned"; exit 1; }
done

echo "ok: the free-space path verifies the root image and the mirror before it formats"
