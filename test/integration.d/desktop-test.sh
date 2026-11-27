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
# clipboard sub-phase (opens the default browser) runs too.

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

# The browser the installed Omarchy opens links with, read the way its own
# launcher reads it: xdg-settings names the desktop entry, and the entry's
# Exec= names the command. 4.5 ships Chromium and quattro Google Chrome
# (omacom/omarchy#18240), so the test names neither. BROWSER and the
# desktop-specific list route back to omarchy-browser.desktop, which only
# hands links to that launcher, so xdg-settings reads neither. Both browsers
# are Chromium builds: windows and cores still match "chrom", and the profile
# lives under the name omarchy-launch-browser focuses by.
read_default_browser() {
  local answer

  answer=$(ssh_session 'entry=$(env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings get default-web-browser) &&
    for dir in ~/.local/share /usr/local/share /usr/share; do
      [[ -f $dir/applications/$entry ]] || continue
      printf "%s %s\n" "$entry" "$(sed -n "s/^Exec=\([^ ]*\).*/\1/p" "$dir/applications/$entry" | head -1)"
      break
    done' 2>/dev/null)
  read -r BROWSER_ENTRY BROWSER_COMMAND <<<"$answer"
  BROWSER_NAME=$(basename "${BROWSER_COMMAND:-none}" -stable)
  log "Default browser: ${BROWSER_ENTRY:-none} runs ${BROWSER_COMMAND:-nothing}"
  check "xdg-settings names a default browser and its command" test -n "$BROWSER_COMMAND"
}

guest_layer_present() {
  local namespace="$1"

  ssh_session "hyprctl -j layers | jq -e --arg namespace '$namespace' \
    '[.. | objects | select(.namespace? == \$namespace)] | length > 0'"
}

guest_layer_absent() {
  ! guest_layer_present "$1"
}

# Close every shortcut surface, so one left open by a failed check cannot hold
# the keyboard for the checks after it. The dock's app picker has no hide
# command; its apps command toggles it.
close_shortcut_surfaces() {
  ssh_session 'for plugin in omarchy.menu omarchy.emojis omarchy.clipboard omarchy.audio; do
    omarchy-shell shell hide "$plugin" >/dev/null 2>&1 || true
  done
  if hyprctl -j layers | jq -e '\''[.. | objects | select(.namespace? == "omarchy-dock-apps")] | length > 0'\'' >/dev/null; then
    omarchy-shell omarchy.dock apps >/dev/null 2>&1 || true
  fi' >/dev/null 2>&1 || true
}

cleanup_shortcut_state() {
  close_shortcut_surfaces
  ssh_session 'while read -r address; do
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$address\" })" >/dev/null 2>&1 ||
      hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || true
  done < <(hyprctl -j clients | jq -r '\''.[] | select(.class == "foot") | .address'\'')
  hyprctl dispatch workspace 1 >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
}

verify_surface_shortcut() {
  local name="$1" chord="$2" namespace="$3"

  press "$chord"
  if ! wait_for_guest_state "$name shortcut opens" 15 guest_layer_present "$namespace"; then
    capture_console "failure-shortcut-$name-open"
    close_shortcut_surfaces
    return 1
  fi
  capture_console "success-shortcut-$name"

  press esc
  if ! wait_for_guest_state "$name shortcut surface closes" 15 guest_layer_absent "$namespace"; then
    capture_console "failure-shortcut-$name-close"
    close_shortcut_surfaces
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
  local copy_token paste_token terminal_token
  copy_token="OmarchyUniversalCopy$(date +%s)"
  paste_token="OmarchyUniversalPaste$(date +%s)"
  terminal_token="OmarchyTerminalPaste$(date +%s)"
  local terminal_result="/tmp/omarchy-universal-terminal-paste"

  cleanup_shortcut_state
  ssh_session "systemd-run --user --quiet --collect --unit=omarchy-browser-smoke-clipboard-\$RANDOM \
    uwsm-app -- '$BROWSER_COMMAND' --new-window about:blank"
  if ! wait_for_guest_state "universal clipboard test opens the default browser" 45 \
    ssh_session "hyprctl -j clients | jq -e '[.[] | select(.class | test(\"(?i)chrom\"))] | length == 1'"; then
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
  done < <(hyprctl -j clients | jq -r '\''.[] | select(.class | test("(?i)chrom")) | .address'\'')' || true

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

  local name chord namespace apps_namespace=omarchy-menu
  # Super+Alt+Space opens the dock's app picker since omacom/omarchy#15263
  # and the menu before it. Expect whichever the installed Omarchy binds.
  if ssh_session "grep -q 'omarchy\.dock[ .]apps' /usr/share/omarchy/default/hypr/bindings/utilities.lua"; then
    apps_namespace=omarchy-dock-apps
  fi
  local shortcuts="menu|meta_l-spc|omarchy-menu
apps|meta_l-alt-spc|$apps_namespace
emojis|meta_l-ctrl-e|omarchy-emojis
clipboard|meta_l-ctrl-v|omarchy-clipboard
audio-panel|meta_l-ctrl-a|omarchy-keyboard-panel"

  cleanup_shortcut_state
  while IFS='|' read -r name chord namespace; do
    verify_surface_shortcut "$name" "$chord" "$namespace" || true
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

  # Without a command there is nothing to launch, and the profile path below
  # would be the whole of ~/.config. read_default_browser has failed already.
  [[ -n $BROWSER_COMMAND ]] || return

  for ((i = 1; i <= launches; i++)); do
    out=$(ssh_session "systemctl --user stop 'omarchy-browser-smoke-*' 2>/dev/null; sleep 1; \
      rm -rf ~/.config/$BROWSER_NAME ~/.cache/$BROWSER_NAME; \
      before=\$(coredumpctl list --no-legend 2>/dev/null | grep -c chrom); \
      systemd-run --user --quiet --collect --unit=omarchy-browser-smoke-$i-\$RANDOM uwsm-app -- '$BROWSER_COMMAND' 'https://example.com/?omarchy-smoke=$i'; \
      sleep 9; \
      after=\$(coredumpctl list --no-legend 2>/dev/null | grep -c chrom); \
      windows=\$(hyprctl -j clients | jq '[.[] | select(.class | test(\"(?i)chrom\"))] | length'); \
      echo \"cores \$before->\$after windows \$windows\"" 2>/dev/null)
    echo "    fresh-profile launch $i: ${out:-no answer}"
    [[ $out =~ ^cores\ ([0-9]+)-\>([0-9]+)\ windows\ ([0-9]+)$ ]] &&
      [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" && ${BASH_REMATCH[3]} -ge 1 ]] || ((failed += 1))
  done
  check "the default browser opens a link on a fresh profile, $launches times, without a core dump (failed: $failed)" test "$failed" -eq 0
  ssh_session "systemctl --user stop 'omarchy-browser-smoke-*'" >/dev/null 2>&1 || true
}

# ------------------------------------------- the Omarchy desktop, not a session

# A Hyprland socket proves a session, not that it is Omarchy's. When Hyprland
# aborts, start-hyprland restarts it with --safe-mode, which loads a generated
# recovery config instead of Omarchy's: no bar, no wallpaper, Hyprland's own
# background and its "safe mode" dialog. That session still answers SSH and
# hyprctl, so every check above passed on it.

# The windows Hyprland opens by itself, from hyprland-guiutils: the update
# news, the donation nag, the welcome window, and the dialogs (the safe-mode
# notice is one). Omarchy turns them off for the session
# (default/hypr/envs.lua) and for the login screen
# (default/sddm/hyprland.lua), and starts none of them itself, so one running
# means a config that did not load, or a screen that config does not cover.
# They are looked for as processes: in the VM their windows do not always map,
# so hyprctl clients can miss one that a real screen shows.
HYPRLAND_POPUPS='hyprland-(update-screen|donate-screen|welcome|dialog)'

# Two measures of the screen, both from 0 to 1, measured on the 4.6.0-rc1 ISO
# in this harness:
#   stddev  the spread of its gray levels. Black, or one flat colour, is 0;
#           a black screen with one 32x32 white patch 0.036; the login screen
#           (logo and password field on near-black) 0.165; the desktop 0.177.
#   bright  the share of its pixels lighter than 10% gray. Black is 0; the
#           safe-mode session 0.076; the desktop's wallpaper 0.925; the login
#           screen's background, just lighter than that, 1.0.
# The login screen is dark by design, so it is judged by the spread; the
# desktop by its wallpaper showing, which a black or near-black frame with a
# bar or a few windows on it would not.
SCREEN_DRAWN_MIN_STDDEV=0.08
WALLPAPER_MIN_BRIGHT=0.5

screen_measure() {
  local what="$1" shot="$RUN_DIR/.drawn.ppm" value="" format

  case $what in
    stddev) format='%[fx:standard_deviation]' ;;
    bright) format='%[fx:mean]' ;;
  esac
  screendump "$shot"
  if [[ -s $shot ]]; then
    if [[ $what == bright ]]; then
      value=$(magick "$shot" -colorspace Gray -threshold 10% -format "$format" info: 2>/dev/null)
    else
      value=$(magick "$shot" -colorspace Gray -format "$format" info: 2>/dev/null)
    fi
  fi
  rm -f "$shot"
  [[ $value =~ ^[0-9]*\.?[0-9]+(e-?[0-9]+)?$ ]] && echo "$value" || echo 0
}

screen_above() {
  awk -v value="$(screen_measure "$1")" -v floor="$2" 'BEGIN { exit !(value + 0 > floor + 0) }'
}

screen_drawn() { screen_above stddev "$SCREEN_DRAWN_MIN_STDDEV"; }
wallpaper_visible() { screen_above bright "$WALLPAPER_MIN_BRIGHT"; }

# The Hyprland a user runs, read once, so it cannot exit between two looks.
hyprland_pid_for() {
  ssh_guest "pgrep -u $1 -x Hyprland"
}

hyprland_not_in_safe_mode_for() {
  ssh_guest "args=\$(pgrep -a -u $1 -x Hyprland) && [[ \$args != *--safe-mode* ]]"
}

# The popups a user runs, one name per line, and "unknown" when they could
# not be read: pgrep exits 1 when nothing matches and 2 or 3 when it could not
# look, and an SSH failure is no answer either. The pattern can't match the
# command that runs pgrep: there it is written "hyprland-(update...", a
# parenthesis where a popup has a letter.
hyprland_popups_for() {
  local out
  out=$(ssh_guest "pgrep -a -u $1 -f '$HYPRLAND_POPUPS'; [[ \$? -le 1 ]] || echo unknown" 2>/dev/null) || out=unknown
  [[ $out == *unknown* ]] && echo unknown
  grep -oE "$HYPRLAND_POPUPS" <<<"$out" || true
}

no_hyprland_popups_for() {
  [[ -z $(hyprland_popups_for "$1") ]]
}

# Hyprland writes a crash report into its user's cache before it aborts, and
# systemd-coredump keeps the core: neither may exist, for the session's
# compositor or for the login screen's. coredumpctl's rows end in the size,
# so the dumps are asked for by executable.
no_hyprland_crash() {
  ssh_sudo 'compgen -G "/home/*/.cache/hyprland/hyprlandCrashReport*.txt" >/dev/null && exit 1
    compgen -G "/var/lib/sddm/.cache/hyprland/hyprlandCrashReport*.txt" >/dev/null && exit 1
    dumps=$(coredumpctl --no-legend --no-pager list /usr/bin/Hyprland 2>&1)
    [[ $? == 1 && $dumps == *"No coredumps found"* ]]'
}

# A value Omarchy sets and Hyprland's default does not: the session loaded
# Omarchy's config, not a recovery or a default one.
omarchy_config_loaded() {
  ssh_session "hyprctl -j getoption ecosystem:no_update_news | jq -e '.bool == true'"
}

# What an assertion here saw, for the artifact: the compositors' command lines,
# the popups, the layers, and the crash records.
diagnose_desktop() {
  local name="$1"
  {
    echo "### Hyprland processes ###"; ssh_guest "pgrep -a -x Hyprland"
    echo "### hyprland-guiutils processes ###"; ssh_guest "pgrep -a -f '$HYPRLAND_POPUPS'"
    echo "### layers ###"; ssh_session "hyprctl -j layers | jq -r '.. | objects | select(.namespace?) | .namespace' | sort | uniq -c"
    echo "### crash reports ###"; ssh_sudo 'ls -la /home/*/.cache/hyprland/ /var/lib/sddm/.cache/hyprland/ 2>&1'
    echo "### coredumps ###"; ssh_sudo 'coredumpctl --no-legend --no-pager list 2>&1'
    echo "### login screen's lastVersion ###"; ssh_sudo 'cat /var/lib/sddm/.local/share/hyprland/lastVersion 2>&1'
    echo "### screen stddev, bright ###"; screen_measure stddev; screen_measure bright
  } >"$RUN_DIR/$name.txt" 2>&1 || true
}

login_greeter_running() {
  # By command line: the kernel keeps 15 characters of a process name, so -x
  # would compare "sddm-greeter-qt".
  ssh_guest "pgrep -u sddm -f '^/usr/bin/sddm-greeter' >/dev/null"
}

# The login screen's compositor, kept for the checks that it stayed the same.
record_login_compositor() {
  LOGIN_COMPOSITOR=$(hyprland_pid_for sddm) && [[ -n $LOGIN_COMPOSITOR ]]
}

# Hyprland records the last version a user ran and opens its update news when
# that is an older major (src/managers/VersionKeeperManager.cpp); the first
# start records 0.0.0. So the login screen's compositor, the sddm user, opens
# it on its second start after an install and on its first after every
# Hyprland upgrade. Put the record Hyprland itself leaves there, start the
# login screen again, and watch its compositor's first seconds: it opens the
# update news within about 2 s unless the login screen's config turns it off.
reset_login_screen_to_after_upgrade() {
  ssh_sudo 'set -e
    systemctl stop sddm
    for _ in $(seq 30); do pgrep -u sddm -x Hyprland >/dev/null || break; sleep 1; done
    if pgrep -u sddm -x Hyprland >/dev/null; then exit 1; fi
    install -d -o sddm -g sddm /var/lib/sddm/.local/share/hyprland
    printf 0.0.0 >/var/lib/sddm/.local/share/hyprland/lastVersion
    chown sddm:sddm /var/lib/sddm/.local/share/hyprland/lastVersion
    [[ $(cat /var/lib/sddm/.local/share/hyprland/lastVersion) == 0.0.0 ]]
    systemctl start sddm'
}

# The login screen of an unencrypted install, which shows it at every boot
# (an encrypted one logs straight in once the disk is unlocked).
verify_login_screen() {
  local before=$FAILURES seen="" unread=false

  if reset_login_screen_to_after_upgrade >/dev/null 2>&1; then
    printf 'ok - %s\n' "the login screen starts again as after a Hyprland upgrade"
  else
    printf 'not ok - %s\n' "the login screen starts again as after a Hyprland upgrade"
    ((FAILURES += 1))
    diagnose_desktop "failure-login-screen"
    return 1
  fi

  wait_for_guest_state "the login screen's compositor is up" 60 record_login_compositor || return 1
  # Its first 15 seconds, the popups open about 2 s in: every popup seen in
  # any of them counts, and a reading that could not be taken is kept apart.
  local reading
  for _ in $(seq 15); do
    reading=$(hyprland_popups_for sddm)
    grep -qx unknown <<<"$reading" && unread=true
    seen+=$(grep -vx unknown <<<"$reading" || true)$'\n'
    sleep 1
  done
  seen=$(sort -u <<<"$seen" | sed '/^$/d')

  wait_for_guest_state "the login screen's greeter is up" 60 login_greeter_running || return 1
  if ! wait_for_guest_state "the login screen is drawn" 60 screen_drawn; then
    diagnose_desktop "failure-login-screen"
    return 1
  fi
  capture_console "success-desktop-00-login-screen"

  check "the login screen's popups could be read" test "$unread" = false
  check "the login screen shows no Hyprland update news" test -z "$(grep -x hyprland-update-screen <<<"$seen")"
  check "the login screen shows no other Hyprland popup" test -z "$(grep -vx hyprland-update-screen <<<"$seen")"
  check "the login screen's Hyprland is not in safe mode" hyprland_not_in_safe_mode_for sddm
  check "the login screen's compositor stayed up" test "$(hyprland_pid_for sddm)" = "$LOGIN_COMPOSITOR"

  ((FAILURES == before)) || diagnose_desktop "failure-login-screen"
}

# The session the owner logged in to is Omarchy's desktop: its compositor
# with its config, its shell drawing the bar and the wallpaper, nothing of
# Hyprland's own on top, and pixels on the screen. The bar and the wallpaper
# may map a moment after the shell answers, so they are waited for.
verify_omarchy_desktop() {
  local before=$FAILURES

  check "the session's Hyprland is not in safe mode" hyprland_not_in_safe_mode_for "$GUEST_USER"
  check "Hyprland has not crashed since the install" no_hyprland_crash
  check "the session runs Omarchy's Hyprland config" omarchy_config_loaded
  wait_for_guest_state "Omarchy's bar is drawn" 30 guest_layer_present omarchy-bar || true
  wait_for_guest_state "Omarchy's wallpaper is drawn" 30 guest_layer_present omarchy-background || true
  check "the desktop shows no Hyprland popup" no_hyprland_popups_for "$GUEST_USER"
  wait_for_guest_state "the desktop's wallpaper is visible" 15 wallpaper_visible || true

  ((FAILURES == before)) || diagnose_desktop "failure-desktop-not-omarchy"
}

# ------------------------------------------------------- reaching the desktop

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

# The first login's setup, omarchy-provision-first-run, runs beside the
# session's first seconds, and its Superwhisper step (omacom/omarchy#17286)
# has the shell reload its plugins: the menu and every panel close, an open
# still loading is dropped, and the wallpaper is gone until they are back.
# Super+Space pressed then opened nothing in about a third of the runs. The
# desktop has settled once that setup is gone and the menu answers again.
# Hyprland starts the setup with the shell, so it is still running when the
# menu first answers; asked together, the two cannot pass before it starts.
# The check's own shell must not spell the name out whole, or pgrep -f finds
# it: hence the [o] and the split quoting. A renamed setup command fails the
# wait instead of quietly letting the flake back in.
desktop_settled() {
  ssh_session 'command -v "omarchy-provision-first-"run >/dev/null &&
    ! pgrep -f "[o]marchy-provision-first-run" >/dev/null &&
    [[ $(omarchy-shell shell call omarchy.menu ping "") == ok ]]'
}

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
  # An encrypted install stops at the disk passphrase first: wait_for_ssh
  # types it, as it does for every other scenario's boot. It waits by itself,
  # says why it gave up and stops when the VM is gone, so it isn't polled.
  if wait_for_ssh "$BOOT_TIMEOUT"; then
    printf 'ok - %s\n' "the installed system boots and answers SSH"
  else
    printf 'not ok - %s\n' "the installed system boots and answers SSH"
    ((FAILURES += 1))
    return 1
  fi
  if ! wait_for_guest_state "the graphical login is ready" 300 login_ready; then
    diagnose_login
    return 1
  fi

  if [[ $ENCRYPT != true ]]; then
    verify_login_screen || return 1
  else
    sleep 3
  fi

  # No capture here: a frame taken right after Enter is the hand-off, black
  # (stddev 0), with the login screen's compositor gone and the session's not
  # drawn yet. The login screen is captured above, before the password.
  type_text "$GUEST_PASSWORD"
  press ret

  if ! wait_for_guest_state "the owner logs in to a Hyprland session" 90 session_started; then
    diagnose_login
    return 1
  fi
  wait_for_guest_state "the session unlocks for the owner" 30 session_unlocked || return 1
  if ! wait_for_guest_state "the desktop settles after the first login's setup" 120 desktop_settled; then
    capture_console "failure-desktop-settle"
    ssh_guest "cat ~/.local/state/omarchy/first-run.log" >"$RUN_DIR/first-run.txt" 2>&1 || true
    ssh_session 'pgrep -af "[o]marchy-provision-first-run"; omarchy-shell shell call omarchy.menu ping ""' \
      >"$RUN_DIR/desktop-settle.txt" 2>&1 || true
    ssh_sudo 'journalctl -b -t omarchy-shell --no-pager' >>"$RUN_DIR/desktop-settle.txt" 2>&1 || true
    return 1
  fi
  verify_omarchy_desktop
  capture_console "success-desktop-01-session"
}

# ---------------------------------------------------------------------- main

if reach_desktop; then
  read_default_browser
  shortcut_smoke_phase
  browser_launch_phase
fi
finish
