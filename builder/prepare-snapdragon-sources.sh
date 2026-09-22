#!/bin/bash
# Pinned Dragon sources for the existing --local-source build contract.
set -euo pipefail
output=${1:?new output directory}
patch_dir=$(cd "$(dirname "$0")/patches" && pwd)
[[ ! -e $output ]] || { echo "Source destination already exists: $output" >&2; exit 1; }
mkdir -p "$output"
checkout() {
  local url=$1 revision=$2 destination=$3
  git init -q "$destination"
  git -C "$destination" remote add origin "$url"
  git -C "$destination" fetch --depth=1 origin "$revision"
  git -C "$destination" checkout -q --detach FETCH_HEAD
  [[ $(git -C "$destination" rev-parse HEAD) == "$revision" ]]
}
checkout https://github.com/omacom/omarchy.git \
  66a33c339914cfa0e41ec1fce8f198ea779b8aea "$output/omarchy"
checkout https://github.com/omacom/omarchy-pkgs.git \
  e0959b06f5f5745dc67ea2f207619a096bd485fd "$output/omarchy-pkgs"
git -C "$output/omarchy-pkgs" apply --check "$patch_dir/snapdragon-arm-package-config.patch"
git -C "$output/omarchy-pkgs" apply "$patch_dir/snapdragon-arm-package-config.patch"
printf '%s\n' "Prepared pinned Dragon runtime and ARM UEFI package recipes in $output"
