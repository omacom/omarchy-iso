#!/bin/bash

# Print exactly one "filename<TAB>sha256" row for the requested Node platform.
# Release manifests use version-prefixed names such as
# node-v24.7.0-linux-arm64.tar.gz, so match the full architecture suffix.
select_node_release() {
  local node_platform=$1
  local suffix="-${node_platform}.tar.gz"

  awk -v suffix="$suffix" '
    length($2) >= length(suffix) && substr($2, length($2) - length(suffix) + 1) == suffix {
      if (found) {
        duplicate = 1
        next
      }
      sha = $1
      filename = $2
      found = 1
    }
    END {
      if (!found || duplicate) exit 1
      print filename "\t" sha
    }
  '
}
