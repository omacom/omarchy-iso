#!/bin/bash
#
# The dashboard asks omarchy-release-install-target to let go of the target
# before it offers the install medium's removal, and that release's verdict
# decides two things the user acts on: whether the finish screen says the
# stick may come out, and whether the button does the medium-free
# `reboot -ff` or the graceful reboot that still pages off it. A release that
# failed while the screen said otherwise is how a machine gets its stick
# pulled mid-read, so the verdict is tested here rather than trusted.
#
# The dashboard's own driver is a screenful of top-level code, so the file is
# sourced up to it: everything above is definitions, which is all this needs.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

fails=0
check() { # desc, expected, actual
  local desc=$1 want=$2 got=$3
  if [[ $got != "$want" ]]; then
    echo "FAIL: $desc (want '$want', got '$got')"; fails=1; return
  fi
  echo "ok: $desc"
}

check_has() { # desc, needle, haystack
  local desc=$1 needle=$2 hay=$3
  if [[ $hay != *"$needle"* ]]; then
    echo "FAIL: $desc (missing '$needle' in: $hay)"; fails=1; return
  fi
  echo "ok: $desc"
}

check_absent() { # desc, needle, haystack
  local desc=$1 needle=$2 hay=$3
  if [[ $hay == *"$needle"* ]]; then
    echo "FAIL: $desc (unexpected '$needle' in: $hay)"; fails=1; return
  fi
  echo "ok: $desc"
}

BOX=$(mktemp -d)
trap 'rm -rf "$BOX"' EXIT
mkdir -p "$BOX/bin" "$BOX/omarchy" "$BOX/units"
printf 'OMARCHY\n' >"$BOX/omarchy/logo.txt"

# The release helper the dashboard shells out to, standing in for the real
# sweep: it echoes the diagnosis a failing sweep writes to stderr and takes
# its exit status from a fixture, which is the whole contract between them.
cat >"$BOX/bin/omarchy-release-install-target" <<'EOF'
#!/bin/bash
echo "release-helper $*" >>"$BOX/calls"
echo "could not unmount $1; holders: init(1)" >&2
exit "$(cat "$BOX/release_rc")"
EOF
cat >"$BOX/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$BOX/calls"
EOF
cat >"$BOX/bin/reboot" <<'EOF'
#!/bin/bash
echo "reboot $*" >>"$BOX/calls"
EOF
cat >"$BOX/bin/ttfx" <<'EOF'
#!/bin/bash
exit 0
EOF
# A no-op jq so the test does not hinge on the host having the real one:
# nothing under test consults it any more (the target comes from the
# environment and the duration from the dashboard's own clock).
cat >"$BOX/bin/jq" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BOX"/bin/*

# The dashboard's definitions, without the driver that would run an install.
awk '/^\[\[ -e \$TTY_PATH \]\] \|\| exit 2$/ { exit } { print }' "$DASHBOARD" >"$BOX/dashboard-defs.sh"

# Run one scenario: source the definitions, set the release verdict the way
# the given helper exit status would, call $1, and leave the tty output, the
# log and the recorded calls behind for the parent to assert on.
scenario() { # function-to-call, release_rc  ->  sets TTY_OUT, LOG_OUT, CALLS
  local fn=$1 release_rc=$2 reader
  echo "$release_rc" >"$BOX/release_rc"
  : >"$BOX/calls"
  : >"$BOX/install.log"
  # The tty is a fifo, not a file: the dashboard reopens it with > for every
  # write, which a real console shrugs off and a regular file answers by
  # truncating away everything drawn before. An fd held open on the write end
  # keeps the reader alive across those reopens.
  : >"$BOX/tty.out"
  rm -f "$BOX/tty.fifo"
  mkfifo "$BOX/tty.fifo"
  cat <"$BOX/tty.fifo" >>"$BOX/tty.out" &
  reader=$!
  (
    export BOX
    PATH="$BOX/bin:$PATH"
    exec 9>"$BOX/tty.fifo"
    OMARCHY_DASHBOARD_TTY="$BOX/tty.fifo" OMARCHY_PATH="$BOX/omarchy" \
      OMARCHY_INSTALL_TARGET="$BOX/mnt" OMARCHY_INSTALL_UNITS_DIR="$BOX/units" \
      source "$BOX/dashboard-defs.sh" "$BOX/install.log" -- true
    release_target
    echo "$TARGET_RELEASED" >"$BOX/released"
    [[ $fn == release_target ]] || "$fn"
  )
  wait "$reader"
  TTY_OUT=$(cat "$BOX/tty.out")
  LOG_OUT=$(cat "$BOX/install.log")
  CALLS=$(cat "$BOX/calls")
  RELEASED=$(cat "$BOX/released")
}

# ── The verdict itself ───────────────────────────────────────────────────────
scenario release_target 0
check "a clean sweep leaves the target released" "yes" "$RELEASED"
check_has "the helper is given the target from the environment" "release-helper $BOX/mnt" "$CALLS"
check_absent "a clean sweep logs no failure" "could not release" "$LOG_OUT"

scenario release_target 1
check "a failed sweep withdraws the release" "no" "$RELEASED"
check_has "the failure is logged" "release: could not release $BOX/mnt" "$LOG_OUT"
check_has "the helper's holder diagnosis is forwarded to the log" "holders: init(1)" "$LOG_OUT"

# ── What the finish screen promises ──────────────────────────────────────────
scenario render_finish 0
check_has "a released target invites the medium out" "You can now remove the install medium" "$TTY_OUT"

scenario render_finish 1
check_has "a held target asks for the medium to stay" \
  "Leave the install medium in until the reboot completes" "$TTY_OUT"
check_absent "and never promises the opposite in the same breath" \
  "You can now remove" "$TTY_OUT"

# ── What the button does ─────────────────────────────────────────────────────
scenario reboot_now 0
check_has "a released target reboots without stop jobs" "systemctl reboot -ff" "$CALLS"

scenario reboot_now 1
check_has "a held target reboots gracefully" "systemctl reboot" "$CALLS"
check_absent "a held target keeps its stop jobs" "-ff" "$CALLS"

if (( fails )); then
  echo "dashboard release gate: FAILED"
  exit 1
fi
echo "ok: the dashboard's removal offer and reboot follow the release"
