#!/bin/bash
#
# When install is pressed while the boot-time hash of the install medium is
# still running, the pre-flight verify phase waits on it for minutes. Its band
# is sized for the subsecond case, so the bar must widen it from the hash's
# real progress and draw the rest of the install compressed after it, without
# ever moving backwards. When the hash already finished, the bar is unchanged.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

fails=0
check() { # desc, condition-exit-status
  if (( $2 )); then echo "FAIL: $1"; fails=1; else echo "ok: $1"; fi
}

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT
mkdir -p "$BOX/omarchy" "$BOX/mnt"
printf 'OMARCHY\n' >"$BOX/omarchy/logo.txt"
: >"$BOX/tty"

# The dashboard's definitions, without the driver that would run an install.
awk '/^\[\[ -e \$TTY_PATH \]\] \|\| exit 2$/ { exit } { print }' "$DASHBOARD" >"$BOX/dashboard-defs.sh"

# Feed a sequence of "phase progress" snapshots (progress -1 for none), one
# second apart, and print the bar's per-mille after each.
run() {
  (
    INSTALLER_I18N="$ROOT/configs/airootfs/usr/share/omarchy-iso/i18n.sh" \
      OMARCHY_DASHBOARD_TTY="$BOX/tty" OMARCHY_PATH="$BOX/omarchy" \
      OMARCHY_EXPECTED_PACKAGES_FILE=/nonexistent \
      PROGRESS_ICON="$ROOT/test/unit/fixtures/progress-icon.sh" \
      source "$BOX/dashboard-defs.sh" "$BOX/install.log" "$BOX/state.json" -- true
    NOW=0
    while IFS='|' read -r phase progress; do
      jq -n --arg phase "$phase" --argjson p "$progress" --arg target "$BOX/mnt" \
        '{current_phase: $phase, target: $target} + (if $p >= 0 then {phase_progress: $p} else {} end)' \
        >"$BOX/state.json"
      NOW=$((NOW + 1))
      install_progress
      echo "$PROGRESS_PM"
    done
  )
}

monotone() { sort -c -n <<<"$1" 2>/dev/null; }

waited=$(run <<'EOF'
Preparing live environment|-1
Preparing install target|0.2
Preparing install target|0.4
Preparing install target|0.6
Preparing install target|0.8
Preparing install target|1.0
Installing Arch + Omarchy|-1
Installing Arch + Omarchy|0.5
Configuring system|-1
EOF
)
mapfile -t w <<<"$waited"
check "a waited-on hash never moves the bar backwards" "$(monotone "$waited"; echo $?)"
check "the hash drives the bar well past the phase's sliver (got ${w[5]})" "$(( w[5] < 200 ))"
check "each hash sample moves the bar (got ${w[1]} ${w[2]} ${w[3]})" "$(( !(w[1] < w[2] && w[2] < w[3]) ))"
check "the next phase starts where the verify left off (got ${w[5]} -> ${w[6]})" "$(( w[6] < w[5] || w[6] > w[5] + 5 ))"

done_already=$(run <<'EOF'
Preparing live environment|-1
Preparing install target|-1
Installing Arch + Omarchy|-1
Configuring system|-1
EOF
)
mapfile -t d <<<"$done_already"
check "a finished hash leaves the verify phase its sliver (got ${d[1]})" "$(( d[1] < 50 || d[1] >= 65 ))"
check "a finished hash leaves later phases on their own bands (got ${d[3]})" "$(( d[3] < 720 ))"

exit "$fails"
