#!/bin/bash
#
# Verify that the install dashboard stays tight to the real install:
# - polls state.json at 5 Hz so fast installs track 1:1
# - skips the redundant sleep 0.4 before release_target on direct installs
# - runs ttfx laseretch at a crisp frame rate (>= 500 fps)
# - reads explicit monotonic duration when present

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

fails=0
check() {
  local desc=$1 want=$2 got=$3
  if [[ $got != "$want" ]]; then
    echo "FAIL: $desc (want '$want', got '$got')"; fails=1; return
  fi
  echo "ok: $desc"
}

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT
mkdir -p "$BOX/bin" "$BOX/omarchy"
printf 'OMARCHY\n' >"$BOX/omarchy/logo.txt"
printf '{"target": "%s/mnt", "started_at": 100.0, "finished_at": 103.67, "duration": 3.67}\n' "$BOX" >"$BOX/state.json"

cat >"$BOX/bin/sleep" <<'STUB'
#!/bin/bash
echo "sleep $*" >>"$BOX/events"
STUB
cat >"$BOX/bin/omarchy-release-install-target" <<'STUB'
#!/bin/bash
echo "release_target" >>"$BOX/events"
exit 0
STUB
cat >"$BOX/bin/ttfx" <<'STUB'
#!/bin/bash
echo "ttfx $*" >>"$BOX/events"
exit 0
STUB
cat >"$BOX/bin/gum" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$BOX/bin/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$BOX/bin/mountpoint" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$BOX"/bin/*

cat >"$BOX/progress-icon.sh" <<'STUB'
progress_icon_layout() { echo "layout" >>"$BOX/events"; }
progress_icon_static() { echo "static" >>"$BOX/events"; }
progress_icon_frame() { echo "frame $1" >>"$BOX/events"; }
progress_icon_finish() { echo "finish" >>"$BOX/events"; }
STUB

: >"$BOX/events"
: >"$BOX/tty.out"
rm -f "$BOX/tty.fifo"
mkfifo "$BOX/tty.fifo"
cat <"$BOX/tty.fifo" >>"$BOX/tty.out" &
reader=$!
(
  export BOX
  PATH="$BOX/bin:$PATH"
  exec 9>"$BOX/tty.fifo"
  INSTALLER_I18N="$ROOT/configs/airootfs/usr/share/omarchy-iso/i18n.sh" \
    OMARCHY_DASHBOARD_TTY="$BOX/tty.fifo" \
    OMARCHY_PATH="$BOX/omarchy" \
    PROGRESS_ICON="$BOX/progress-icon.sh" \
    OMARCHY_UI_INTERACTIVE=no \
    OMARCHY_UI_AUTO_REBOOT=no \
    "$DASHBOARD" "$BOX/install.log" "$BOX/state.json" -- true
)
wait "$reader"

# 1. Direct install must not sleep 0.4 between progress_icon_finish and release_target.
between=$(awk '/^finish$/{flag=1; next} /^release_target$/{flag=0} flag' "$BOX/events")
check "no sleep between progress_icon_finish and release_target on direct install" "" "$between"

# 2. ttfx laseretch frame-rate should be >= 500 fps.
fps=$(awk '/^ttfx .*laseretch/ { for (i=1; i<=NF; i++) if ($i=="--frame-rate") print $(i+1) }' "$BOX/events" | tail -n1)
if [[ -n $fps ]] && (( fps >= 500 )); then
  echo "ok: ttfx laseretch runs at >= 500 fps ($fps)"
else
  echo "FAIL: ttfx laseretch frame-rate too slow (got '${fps:-missing}')"
  fails=1
fi

# 3. Poll cadence: update_progress runs at least every 2 frames (5 Hz), not every 5 frames (2 Hz).
if grep -Eq '\(\( frame % 2 == 0 \)\)[[:space:]]*&&[[:space:]]*update_progress' "$DASHBOARD"; then
  echo "ok: dashboard polls state.json at 5 Hz (every 2 frames)"
else
  echo "FAIL: dashboard still polls state.json slower than 5 Hz"
  fails=1
fi

# 4. install_duration prefers explicit monotonic duration when present.
awk '/^\[\[ -e \$TTY_PATH \]\] \|\| exit 2$/ { exit } { print }' "$DASHBOARD" >"$BOX/defs.sh"
printf '{"started_at": 100.0, "finished_at": 3703.67, "duration": 3.67}\n' >"$BOX/skew.json"
got_dur=$(
  INSTALLER_I18N="$ROOT/configs/airootfs/usr/share/omarchy-iso/i18n.sh" \
    OMARCHY_DASHBOARD_TTY=/dev/null \
    OMARCHY_PATH="$BOX/omarchy" \
    PROGRESS_ICON="$BOX/progress-icon.sh" \
    bash -c 'source "$1" "$2" "$3" -- true; install_duration' _ "$BOX/defs.sh" "$BOX/install.log" "$BOX/skew.json"
)
check "install_duration uses monotonic duration field when present" "3.67s" "$got_dur"

if (( fails )); then
  echo "dashboard animation test: FAILED"
  exit 1
fi
echo "dashboard animation test: PASSED"
