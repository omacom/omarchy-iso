#!/bin/bash
#
# Desktop smoke: after a real first-boot provisioning, prove the graphical
# session comes up and Omarchy's primary keybindings actually drive it --
# launcher surfaces, terminals, tiling, floating, and workspaces -- checked
# through Hyprland's own IPC (hyprctl/jq) rather than screenshots. Ported from
# bin/omarchy-iso-test's shortcut_smoke_phase into the base-image framework so
# it runs per-PR alongside the install matrix.
#
# Runs on the default variant only: desktop behaviour does not vary by disk
# size, encryption, or bootloader, and the smoke is expensive. The universal
# clipboard sub-phase (opens Chromium) is deliberately left for a follow-up
# once the session + core shortcuts are proven green in CI.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

if [[ ${VARIANT:-default} != default ]]; then
  log "Desktop smoke runs on the default variant only; skipping for ${VARIANT:-default}"
  exit 0
fi

# ------------------------------------------------------ session-scoped helpers

session_started() {
  ssh_guest "ls /run/user/1000/hypr 2>/dev/null | grep -q ." 2>/dev/null
}

# Run a command inside the graphical user's session: export the Wayland and
# Hyprland environment the login session owns, so hyprctl/wl-clipboard talk to
# the running compositor rather than a bare SSH shell.
ssh_session() {
  local command="$1"

  ssh_guest "export XDG_RUNTIME_DIR=/run/user/\$(id -u); \
    export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus; \
    export LANG=\$(systemctl --user show-environment | sed -n 's/^LANG=//p' | head -1); \
    export LANG=\${LANG:-C.UTF-8}; \
    export HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t \$XDG_RUNTIME_DIR/hypr | head -1); \
    export WAYLAND_DISPLAY=\$(find \$XDG_RUNTIME_DIR -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\\n' | head -1); \
    export OMARCHY_PATH=/usr/share/omarchy; \
    export PATH=\$OMARCHY_PATH/bin:\$PATH; \
    $command" </dev/null
}

# Poll a guest predicate until it holds; records the result as a tap-style
# assertion so it lands in the run tally and in FAILURES (which finish reads).
wait_for_guest_state() {
  local description="$1" timeout="$2"
  shift 2
  local deadline=$((SECONDS + timeout))

  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      printf 'not ok - %s\n' "$description"
      ((FAILURES += 1))
      return 1
    fi
    sleep 1
  done

  printf 'ok - %s\n' "$description"
}

guest_layer_present() {
  local namespace="$1"

  ssh_session "hyprctl -j layers | jq -e --arg namespace '$namespace' \
    '[.. | objects | select(.namespace? == \$namespace)] | length > 0'"
}

guest_layer_absent() {
  ! guest_layer_present "$1"
}

cleanup_shortcut_state() {
  ssh_session 'for plugin in omarchy.menu omarchy.emojis omarchy.clipboard omarchy.audio; do
    omarchy-shell shell hide "$plugin" >/dev/null 2>&1 || true
  done
  while read -r address; do
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null 2>&1 ||
      hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || true
  done < <(hyprctl -j clients | jq -r '\''.[] | select(.class == "foot") | .address'\'')
  hyprctl dispatch workspace 1 >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
}

verify_surface_shortcut() {
  local name="$1" chord="$2" namespace="$3" plugin="$4"

  press "$chord"
  if ! wait_for_guest_state "$name shortcut opens" 15 guest_layer_present "$namespace"; then
    capture_console "failure-shortcut-$name-open"
    ssh_session "omarchy-shell shell hide '$plugin' >/dev/null 2>&1 || true" || true
    return 1
  fi
  capture_console "success-shortcut-$name"

  press esc
  if ! wait_for_guest_state "$name shortcut surface closes" 15 guest_layer_absent "$namespace"; then
    capture_console "failure-shortcut-$name-close"
    ssh_session "omarchy-shell shell hide '$plugin' >/dev/null 2>&1 || true" || true
    return 1
  fi
}

verify_desktop_shortcuts() {
  cleanup_shortcut_state

  press meta_l-ret
  if ! wait_for_guest_state "terminal shortcut opens a window" 30 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class == \"foot\")] | length == 1'"; then
    capture_console "failure-shortcut-terminal-open"
    return 1
  fi

  press meta_l-ret
  if ! wait_for_guest_state "terminal shortcut opens a second window" 30 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class == \"foot\")] | length == 2'"; then
    capture_console "failure-shortcut-terminal-second-window"
    return 1
  fi
  capture_console "success-shortcut-desktop-01-two-tiled-terminals"

  press meta_l-t
  if ! wait_for_guest_state "floating shortcut floats the active window" 15 \
    ssh_session "hyprctl -j activewindow | jq -e '.class == \"foot\" and .floating == true'"; then
    capture_console "failure-shortcut-window-float"
    return 1
  fi
  capture_console "success-shortcut-desktop-02-floating-terminal"

  press meta_l-t
  if ! wait_for_guest_state "floating shortcut returns the window to tiling" 15 \
    ssh_session "hyprctl -j activewindow | jq -e '.class == \"foot\" and .floating == false'"; then
    capture_console "failure-shortcut-window-retile"
    return 1
  fi

  press meta_l-shift-2
  if ! wait_for_guest_state "move shortcut follows the window to workspace 2" 15 \
    ssh_session "hyprctl -j activeworkspace | jq -e '.id == 2' && \
      hyprctl -j activewindow | jq -e '.class == \"foot\" and .workspace.id == 2'"; then
    capture_console "failure-shortcut-window-workspace-2"
    return 1
  fi
  capture_console "success-shortcut-desktop-03-terminal-on-workspace-2"

  press meta_l-1
  if ! wait_for_guest_state "workspace shortcut returns to workspace 1" 15 \
    ssh_session "hyprctl -j activeworkspace | jq -e '.id == 1'"; then
    capture_console "failure-shortcut-workspace-1"
    return 1
  fi
  capture_console "success-shortcut-desktop-04-workspace-1"

  press meta_l-w
  if ! wait_for_guest_state "close shortcut closes the workspace 1 terminal" 15 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class == \"foot\")] | length == 1'"; then
    capture_console "failure-shortcut-close-workspace-1"
    return 1
  fi

  press meta_l-2
  if ! wait_for_guest_state "workspace shortcut visits workspace 2" 15 \
    ssh_session "hyprctl -j activeworkspace | jq -e '.id == 2'"; then
    capture_console "failure-shortcut-visit-workspace-2"
    return 1
  fi
  press meta_l-w
  if ! wait_for_guest_state "close shortcut closes the workspace 2 terminal" 15 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class == \"foot\")] | length == 0'"; then
    capture_console "failure-shortcut-close-workspace-2"
    return 1
  fi
}

verify_universal_clipboard_shortcuts() {
  local copy_token="OmarchyUniversalCopy$(date +%s)"
  local paste_token="OmarchyUniversalPaste$(date +%s)"
  local terminal_token="OmarchyTerminalPaste$(date +%s)"
  local terminal_result="/tmp/omarchy-universal-terminal-paste"

  cleanup_shortcut_state
  ssh_session "setsid -f chromium --new-window about:blank >/dev/null 2>&1"
  if ! wait_for_guest_state "universal clipboard test opens Chromium" 45 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class | test(\"(?i)chromium\"))] | length == 1'"; then
    capture_console "failure-shortcut-universal-clipboard-browser"
    return 1
  fi

  press ctrl-l
  type_text "$copy_token"
  press ctrl-a
  press meta_l-c
  if ! wait_for_guest_state "universal copy uses the active GUI application" 15 \
    ssh_session "[[ \$(wl-paste --no-newline) == '$copy_token' ]]"; then
    capture_console "failure-shortcut-universal-copy"
    return 1
  fi

  ssh_session "setsid -f bash -c 'printf \"%s\" \"$paste_token\" | wl-copy' >/dev/null 2>&1"
  if ! wait_for_guest_state "universal paste clipboard is seeded" 15 \
    ssh_session "[[ \$(wl-paste --no-newline) == '$paste_token' ]]"; then
    capture_console "failure-shortcut-universal-paste-seed"
    return 1
  fi
  press ctrl-l
  press meta_l-v
  sleep 1
  press ctrl-a
  press ctrl-c
  if ! wait_for_guest_state "universal paste uses the active GUI application" 15 \
    ssh_session "[[ \$(wl-paste --no-newline) == '$paste_token' ]]"; then
    capture_console "failure-shortcut-universal-paste-gui"
    return 1
  fi
  capture_console "success-shortcut-universal-copy-paste-gui"
  ssh_session 'while read -r address; do
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null 2>&1 ||
      hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || true
  done < <(hyprctl -j clients | jq -r '\''.[] | select(.class | test("(?i)chromium")) | .address'\'')' || true

  ssh_session "rm -f '$terminal_result'; \
    setsid -f bash -c 'printf \"%s\" \"$terminal_token\" | wl-copy' >/dev/null 2>&1; \
    setsid -f foot --app-id=foot -e bash -c 'read -r value; printf \"%s\" \"\$value\" > \"$terminal_result\"; sleep 30' >/dev/null 2>&1"
  if ! wait_for_guest_state "terminal paste clipboard is seeded" 15 \
    ssh_session "[[ \$(wl-paste --no-newline) == '$terminal_token' ]]"; then
    capture_console "failure-shortcut-universal-paste-terminal-seed"
    return 1
  fi
  if ! wait_for_guest_state "universal clipboard test opens a terminal" 30 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class == \"foot\")] | length == 1'"; then
    capture_console "failure-shortcut-universal-clipboard-terminal"
    return 1
  fi

  press meta_l-v
  sleep 1
  press ret
  if ! wait_for_guest_state "universal paste uses the terminal-safe shortcut" 15 \
    ssh_session "[[ \$(cat '$terminal_result' 2>/dev/null) == '$terminal_token' ]]"; then
    capture_console "failure-shortcut-universal-paste-terminal"
    return 1
  fi
  capture_console "success-shortcut-universal-paste-terminal"
  cleanup_shortcut_state
}

shortcut_smoke_phase() {
  log "Exercising primary desktop shortcuts through the VM keyboard"

  local name chord namespace plugin
  local shortcuts='menu|meta_l-spc|omarchy-menu|omarchy.menu
apps-menu|meta_l-alt-spc|omarchy-menu|omarchy.menu
emojis|meta_l-ctrl-e|omarchy-emojis|omarchy.emojis
clipboard|meta_l-ctrl-v|omarchy-clipboard|omarchy.clipboard
audio-panel|meta_l-ctrl-a|omarchy-keyboard-panel|omarchy.audio'

  cleanup_shortcut_state
  while IFS='|' read -r name chord namespace plugin; do
    verify_surface_shortcut "$name" "$chord" "$namespace" "$plugin" || true
  done <<<"$shortcuts"

  verify_desktop_shortcuts || true
  verify_universal_clipboard_shortcuts || true
  cleanup_shortcut_state
}

# ---------------------------------------------------------- browser launches

# The browser the way the session starts it for a link (xdg-open, a login
# flow, a notification): a transient user unit running uwsm-app with a URL,
# on a profile that has never been used. On real hardware that exact launch
# died once with SIGSEGV 2.2 s in, before any window (first boot of a fresh
# install). 24 such launches in VMs were clean, so this guards
# the path rather than reproduces the crash: a window must appear and no
# core may be recorded, each time on a fresh profile.
browser_launch_phase() {
  local launches=${OMARCHY_BROWSER_LAUNCHES:-3} i out failed=0

  for ((i = 1; i <= launches; i++)); do
    out=$(ssh_session "pkill -x chromium 2>/dev/null; sleep 1; rm -rf ~/.config/chromium ~/.cache/chromium; \
      before=\$(coredumpctl list --no-legend 2>/dev/null | grep -c chromium); \
      systemd-run --user --quiet --collect --unit=omarchy-browser-smoke-$i-\$RANDOM uwsm-app -- /usr/bin/chromium 'https://example.com/?omarchy-smoke=$i'; \
      sleep 9; \
      after=\$(coredumpctl list --no-legend 2>/dev/null | grep -c chromium); \
      windows=\$(hyprctl -j clients | jq '[.[] | select(.class | test(\"(?i)chrom\"))] | length'); \
      echo \"cores \$before->\$after windows \$windows\"" 2>/dev/null)
    echo "    fresh-profile launch $i: ${out:-no answer}"
    [[ $out =~ ^cores\ ([0-9]+)-\>([0-9]+)\ windows\ ([0-9]+)$ ]] &&
      [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" && ${BASH_REMATCH[3]} -ge 1 ]] || ((failed += 1))
  done
  check "chromium opens a link on a fresh profile, $launches times, without a core dump (failed: $failed)" test "$failed" -eq 0
  ssh_session "pkill -x chromium" >/dev/null 2>&1 || true
}

# ------------------------------------------------------- reaching the desktop

ssh_ready() { ssh_guest true; }

# The base was provisioned at install time (cidata created the owner), so it
# boots straight to a graphical login -- the Omarchy logo over a password field
# -- rendered by a Wayland greeter running as its own user, not the first-boot
# wizard. It can take input once any Wayland compositor is up.
login_ready() {
  ssh_guest "ls /run/user/*/wayland-* >/dev/null 2>&1 \
    || systemctl is-active greetd >/dev/null 2>&1 \
    || pgrep -x Hyprland >/dev/null 2>&1"
}

session_unlocked() { ! ssh_guest "pgrep -x hyprlock" >/dev/null 2>&1; }

# Ground truth for when a wait above times out: what is actually running, who is
# logged in, and where the Wayland/Hypr sockets live. Lands in the artifact.
diagnose_login() {
  {
    echo "### ps (user,comm) ###";       ssh_guest "ps -eo user:16,comm --no-headers | sort -u"
    echo "### loginctl ###";             ssh_guest "loginctl list-sessions; echo; loginctl list-users"
    echo "### /run/user ###";            ssh_guest "ls -la /run/user/*/ 2>&1; echo; ls /run/user/*/wayland-* /run/user/*/hypr 2>&1"
    echo "### graphical/greeter units ###"; ssh_guest "systemctl --no-legend --state=running list-units | grep -iE 'greet|display|hypr|seatd|ly|sddm|gdm|uwsm|getty'"
  } >"$RUN_DIR/login-diagnostics.txt" 2>&1 || true
  log "Captured login diagnostics to $RUN_DIR/login-diagnostics.txt"
}

reach_desktop() {
  log "Booting the installed system and logging the owner in"
  start_vm_from_base

  # Every step is a tap assertion (wait_for_guest_state prints ok/not ok and
  # feeds FAILURES), so a stall here is visible and fails the job instead of
  # being masked by the known-failures filter.
  wait_for_guest_state "the installed system boots and answers SSH" "$BOOT_TIMEOUT" ssh_ready || return 1
  if ! wait_for_guest_state "the graphical login is ready" 300 login_ready; then
    diagnose_login
    return 1
  fi

  sleep 3
  type_text "$GUEST_PASSWORD"
  press ret
  capture_console "success-desktop-00-login"

  if ! wait_for_guest_state "the owner logs in to a Hyprland session" 90 session_started; then
    diagnose_login
    return 1
  fi
  wait_for_guest_state "the session unlocks for the owner" 30 session_unlocked || return 1
  capture_console "success-desktop-01-session"
}

# ---------------------------------------------------------------------- main

if reach_desktop; then
  shortcut_smoke_phase
  browser_launch_phase
fi
finish
