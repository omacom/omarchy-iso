#!/bin/bash
# Use the Dragon team's pending recipes until the package channel publishes them.
set -euo pipefail
output=${1:?recipe destination}
mkdir -p "$output"
gitdir=$(mktemp -d)
trap 'rm -rf "$gitdir"' EXIT
git init --bare -q "$gitdir"
for entry in \
  qcom-firmware-extract:4a232b639957a251bfe9220d7d253b95fe5ae635 \
  linux-aarch64-pkgbase-shim:3951d934ccd30b72b68f3d954a220b830fb8143d; do
  name=${entry%%:*}
  revision=${entry#*:}
  git -c gc.auto=0 -c maintenance.auto=false -C "$gitdir" fetch --depth=1 https://github.com/omacom/omarchy-pkgs.git "$revision"
  [[ $(git -C "$gitdir" rev-parse FETCH_HEAD) == "$revision" ]]
  mkdir -p "$output/$name"
  git -C "$gitdir" archive "$revision" "pkgbuilds/$name" |
    tar -xf - --strip-components=2 -C "$output/$name"
done
