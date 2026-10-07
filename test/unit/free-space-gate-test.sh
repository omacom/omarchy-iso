#!/bin/bash
#
# The free-space install formats inside the configurator, so the configurator
# is the only thing that can refuse a bad install medium before parted, wipefs,
# luksFormat and mkfs have already run. The full-disk path has an integration
# scenario for its gate (corrupt-image-test.sh, which autoinstalls from cidata
# and so never reaches the configurator at all); this path has none, and
# deleting its gate outright leaves ./test/all green. Assert the ordering
# statically instead: whatever else moves, omarchy-wait-root-image-verify has
# to run before run_partition_execute.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"

# Comment lines are dropped first: the branch below is explained in prose that
# names both the helper and the function, so matching them would find the
# explanation whether or not the code still does it.
line_of() { # what, pattern -> the one line number matching it
  local what=$1 pattern=$2 hits
  hits=$(grep -vnE '^\s*#' "$configurator" | grep -E ":$pattern" | cut -d: -f1)
  if [[ $(grep -c . <<<"$hits") -ne 1 ]]; then
    echo "expected exactly one $what in ${configurator#"$ROOT/"}, found: ${hits:-none}" >&2
    exit 1
  fi
  printf '%s\n' "$hits"
}

branch=$(line_of "free_space branch" 'if \[\[ \$install_target == "free_space" \]\]; then$')
gate=$(line_of "call to the verify gate" '.*omarchy-wait-root-image-verify')
format=$(line_of "call to run_partition_execute" '\s+run_partition_execute ')

((branch < gate)) ||
  { echo "the verify gate is outside the free_space branch (branch $branch, gate $gate)"; exit 1; }
((gate < format)) ||
  { echo "run_partition_execute runs before the verify gate (gate $gate, format $format): a corrupt install medium would be found only after the disk was partitioned"; exit 1; }

echo "ok: the free-space path verifies the install medium before it formats"
