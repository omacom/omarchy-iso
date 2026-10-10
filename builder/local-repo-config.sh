#!/bin/bash
set -euo pipefail

# Local rebuilds must take precedence over distribution packages.
awk '
  /^\[omarchy\]$/ { skip = 1; next }
  /^\[/ { skip = 0 }
  skip { next }
  /^\[/ && $0 != "[options]" && !inserted {
    print "[omarchy]\nSigLevel = Optional TrustAll\nServer = file:///omarchy-repo\n"
    inserted = 1
  }
  { print }
  END {
    if (!inserted)
      print "\n[omarchy]\nSigLevel = Optional TrustAll\nServer = file:///omarchy-repo"
  }
' "$1"
