#!/bin/bash
#
# The integration harness learns which Omarchy runtime an ISO installs from
# the ISO's name, which bin/omarchy-iso-make ends with the build's ref. It
# answers the installer with those package names and checks the installed
# system for them, so a wrong guess fails an install that worked. This runs
# base-test.sh's own detect_packages against the name of every kind of ISO.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
eval "$(sed -n '/^detect_packages() {$/,/^}$/p' "$ROOT/test/integration.d/base-test.sh")"
declare -F detect_packages >/dev/null || { echo "FAIL: no detect_packages in test/integration.d/base-test.sh"; exit 1; }

fails=0
expect() { # iso name, runtime, settings
  local RUNTIME_PACKAGE SETTINGS_PACKAGE
  ISO="release/$1" detect_packages
  if [[ $RUNTIME_PACKAGE == "$2" && $SETTINGS_PACKAGE == "$3" ]]; then
    echo "ok - $1 installs $2"
  else
    echo "FAIL: $1 should install $2 and $3, the harness says $RUNTIME_PACKAGE and $SETTINGS_PACKAGE"
    fails=$((fails + 1))
  fi
}

expect omarchy-2026.11.10-x86_64-edge.iso omarchy-dev omarchy-settings-dev
expect omarchy-2026.11.10-x86_64-local.iso omarchy-dev omarchy-settings-dev
expect omarchy-2026.11.10-x86_64-dev.iso omarchy-dev omarchy-settings-dev
expect omarchy-2026.11.10-aarch64-devssh-edge.iso omarchy-dev omarchy-settings-dev
expect omarchy-2026.11.10-x86_64-rc.iso omarchy omarchy-settings
expect omarchy-2026.11.10-x86_64-quattro.iso omarchy omarchy-settings
expect omarchy-4.5.0-x86.iso omarchy omarchy-settings
expect omarchy-4.5.0-aarch64.iso omarchy omarchy-settings
# bin/omarchy-iso-make --rehearsal: built from local sources, but the release
# packages, as a release candidate installs them.
expect omarchy-2026.11.10-x86_64-rehearsal.iso omarchy omarchy-settings
expect omarchy-2026.11.10-aarch64-rehearsal.iso omarchy omarchy-settings

# The name comes from the ref --rehearsal sets.
grep -q '^  OMARCHY_ISO_REF=rehearsal$' "$ROOT/bin/omarchy-iso-make" ||
  { echo "FAIL: bin/omarchy-iso-make --rehearsal does not set the rehearsal ref"; fails=$((fails + 1)); }

exit $((fails > 0))
