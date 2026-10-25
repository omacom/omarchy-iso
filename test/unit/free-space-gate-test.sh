#!/bin/bash
#
# The free-space install formats inside the configurator, so the configurator
# is the only thing that can refuse a bad install medium before parted, wipefs,
# luksFormat and mkfs have already run. The full-disk path has an integration
# scenario for its gate (corrupt-image-test.sh, which autoinstalls from cidata
# and so never reaches the configurator at all); this path has none, and
# deleting its gate outright leaves ./test/all green. Assert the ordering
# statically instead: both disk-writing paths must call the shared verification
# gate, and the free-space call has to precede run_partition_execute.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"

# Comment lines are dropped first: the branch below is explained in prose that
# names both the helper and the function, so matching them would find the
# explanation whether or not the code still does it.
line_of() { # what, pattern -> the one line number matching it
  local what=$1 pattern=$2 hits
  hits=$(grep -vnE '^[[:space:]]*#' "$configurator" | grep -E ":$pattern" | cut -d: -f1)
  if [[ $(grep -c . <<<"$hits") -ne 1 ]]; then
    echo "expected exactly one $what in ${configurator#"$ROOT/"}, found: ${hits:-none}" >&2
    exit 1
  fi
  printf '%s\n' "$hits"
}

helper=$(line_of "install-medium verification helper" 'verify_install_medium_before_disk_write\(\) \{$')
verifier=$(line_of "call to omarchy-wait-root-image-verify" '.*omarchy-wait-root-image-verify')
branch=$(line_of "free_space branch" 'if \[\[ \$install_target == "free_space" \]\]; then$')
format=$(line_of "call to run_partition_execute" '[[:space:]]+run_partition_execute ')

gates=$(grep -vnE '^[[:space:]]*#' "$configurator" |
  grep -E ':[[:space:]]+verify_install_medium_before_disk_write( \|\| .*)?$' | cut -d: -f1)
if [[ $(grep -c . <<<"$gates") -ne 2 ]]; then
  echo "expected the full-disk and free-space paths to call the verification helper, found: ${gates:-none}" >&2
  exit 1
fi
full_disk_gate=$(sed -n '1p' <<<"$gates")
free_space_gate=$(sed -n '2p' <<<"$gates")

((helper < verifier && verifier < full_disk_gate)) ||
  { echo "the shared verification helper does not run the verifier before its first caller"; exit 1; }
((full_disk_gate < branch)) ||
  { echo "the full-disk confirmation does not call the verification gate before the free-space branch"; exit 1; }
((branch < free_space_gate)) ||
  { echo "the verify gate is outside the free_space branch (branch $branch, gate $free_space_gate)"; exit 1; }
((free_space_gate < format)) ||
  { echo "run_partition_execute runs before the verify gate (gate $free_space_gate, format $format): a corrupt install medium would be found only after the disk was partitioned"; exit 1; }

echo "ok: both disk-writing paths verify the install medium before destructive work"
