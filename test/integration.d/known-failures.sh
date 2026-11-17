# Sourced by base-test.sh: which failing assertions test/known-failures.txt
# allows, and until when.

KNOWN_FAILURES_FILE="${OMARCHY_INTEGRATION_KNOWN_FAILURES:-$ROOT/test/known-failures.txt}"

# The date until which test/known-failures.txt allows this scenario's
# assertion to fail; nothing when it is not listed or the date has passed.
known_failure_until() {
  local description="$1"
  [[ -f $KNOWN_FAILURES_FILE ]] || return 0
  awk -v scenario="$SCENARIO" -v description="$description" -v today="$(date +%F)" '
    /^[[:space:]]*(#|$)/ { next }
    {
      until = $1; listed = $2
      sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "")
      if (listed == scenario && $0 == description && until >= today) { print until; exit }
    }' "$KNOWN_FAILURES_FILE"
}
