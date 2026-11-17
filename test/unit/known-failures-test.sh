#!/bin/bash
#
# test/known-failures.txt lets a named assertion of a named scenario fail
# until a date. Checked here: the match needs the scenario and the exact
# assertion, an entry stops counting the day after its date, and comments and
# blank lines are skipped.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

today=$(date +%F)
tomorrow=$(date -d tomorrow +%F)
yesterday=$(date -d yesterday +%F)

cat >"$TMP/known" <<LIST
# a comment

$tomorrow factory-reset windows entry survives staging
$today pxe booted in legacy BIOS mode
$yesterday boot no failed units
LIST

export OMARCHY_INTEGRATION_KNOWN_FAILURES="$TMP/known"
source "$ROOT/test/integration.d/known-failures.sh"

fails=0
expect() {
  local description="$1" want="$2" got="$3"
  if [[ $got == "$want" ]]; then
    echo "ok: $description"
  else
    echo "FAIL: $description (wanted '$want', got '$got')"
    fails=1
  fi
}

SCENARIO=factory-reset
expect "a listed assertion is allowed until its date" "$tomorrow" "$(known_failure_until "windows entry survives staging")"
expect "another assertion of the same scenario is not" "" "$(known_failure_until "windows boot payload survives staging")"
expect "part of an assertion does not match" "" "$(known_failure_until "windows entry survives")"

SCENARIO=firmware-boot
expect "the same text in another scenario is not allowed" "" "$(known_failure_until "booted in legacy BIOS mode")"

SCENARIO=pxe
expect "an entry still counts on its date" "$today" "$(known_failure_until "booted in legacy BIOS mode")"

SCENARIO=boot
expect "an entry past its date no longer counts" "" "$(known_failure_until "no failed units")"

OMARCHY_INTEGRATION_KNOWN_FAILURES="$TMP/missing"
source "$ROOT/test/integration.d/known-failures.sh"
expect "without the file nothing is allowed" "" "$(known_failure_until "no failed units")"

[[ $fails -eq 0 ]] && echo "ok: known failures are matched by scenario, assertion and date"
exit "$fails"
