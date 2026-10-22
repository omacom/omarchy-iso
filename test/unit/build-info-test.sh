#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Exercise the builder's metadata block without running package or disk setup.
sed -n '/^if \[\[ ${OMARCHY_INSTALL_DEBUG:-} == "1" \]\]; then$/,/^# When --local-source/p' \
  "$ROOT/builder/build-iso.sh" > "$fixture/build-info.sh"
OMARCHY_ISO_REF=quattro
OMARCHY_ISO_COMMIT=test-iso-commit
OMARCHY_MIRROR=edge
OMARCHY_RUNTIME_PACKAGE=omarchy
OMARCHY_SETTINGS_PACKAGE=omarchy-settings
OMARCHY_NVIM_PACKAGE=omarchy-nvim
for debug in 0 1; do
  build_cache_dir=$fixture/$debug
  share=$build_cache_dir/airootfs/usr/share/omarchy-iso
  mkdir -p "$share"
  OMARCHY_INSTALL_DEBUG=$debug source "$fixture/build-info.sh"
  grep -Fxq "debug=$debug" "$share/build-info"
  grep -Eq '^built_at=.+$' "$share/build-info"
  grep -Fxq 'omarchy_iso_commit=test-iso-commit' "$share/build-info"
  grep -Fxq 'runtime_package=omarchy' "$share/build-info"
  if [[ $debug == 1 ]]; then
    [[ -f $share/install-debug ]]
  else
    [[ ! -e $share/install-debug ]]
  fi
done
echo 'PASS: normal and debug ISOs supply install metadata; debug mode stays opt-in'
