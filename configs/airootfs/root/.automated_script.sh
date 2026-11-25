#!/usr/bin/env bash
#
# Live ISO entry point on tty1: set up the live VT, run the configurator
# wizard, then hand off to the Python install orchestrator. Mirrors the
# stream/env contract from the previously-working installer:
#   - stdout teed to /var/log/omarchy-install.log (CSI-stripped) AND to tty
#   - stderr direct to /dev/tty so gum (which draws its TUI on stderr)
#     renders correctly
#   - CLICOLOR_FORCE/FORCE_COLOR so gum emits ANSI even with stdout piped
#   - COLUMNS/LINES so gum picks up real terminal size
set -euo pipefail

# Inside kmscon this runs again on kmscon's pty: the wizard and the install
# are shown there, in real fonts, and tty1 waits.
[[ $(tty) == /dev/tty1 || ${OMARCHY_KMSCON:-} == 1 ]] || exit 0

# The live boot hides the console's cursor (vt.global_cursor_default=0), so
# nothing blinks on the black screen before the installer draws. A shell left
# here after this script needs it back.
[[ ${OMARCHY_KMSCON:-} == 1 ]] || trap 'printf "\e[?25h" >/dev/tty1 2>/dev/null' EXIT

# The N1x recovery boot entry is a diagnostic shell, never the installer: record
# the hardware probe, show how to reach the machine, and leave tty1 at a prompt.
if grep -qw 'omarchy.n1x_recovery=1' /proc/cmdline; then
  /usr/local/sbin/omarchy-n1x-live-probe || true
  exit 0
fi

export OMARCHY_MIRROR="$(cat /root/omarchy_mirror)"
if [[ -f /root/omarchy_iso_ref ]]; then
  export OMARCHY_ISO_REF="$(cat /root/omarchy_iso_ref)"
fi
if [[ -f /usr/share/omarchy-iso/package-targets ]]; then
  # shellcheck disable=SC1091
  source /usr/share/omarchy-iso/package-targets
  export OMARCHY_RUNTIME_PACKAGE OMARCHY_SETTINGS_PACKAGE OMARCHY_NVIM_PACKAGE
fi
export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL=$OMARCHY_PATH/install
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
if [[ -f /usr/share/omarchy-iso/install-debug ]]; then
  export OMARCHY_INSTALL_DEBUG=1
fi

# gum's key hints ("enter submit") are hardcoded English and add nothing to
# prompts that already say what to do, so every widget leaves them off.
export GUM_CHOOSE_SHOW_HELP=false GUM_CONFIRM_SHOW_HELP=false GUM_FILTER_SHOW_HELP=false GUM_INPUT_SHOW_HELP=false

# Tokyo Night palette so the live VT matches the installed look, for the
# installs drawn on it (OEM and cidata). The console stays black, untouched,
# under an install kmscon draws.
set_tokyo_night_colors() {
  echo -en "\e]P01a1b26"; echo -en "\e]P1f7768e"; echo -en "\e]P29ece6a"
  echo -en "\e]P3e0af68"; echo -en "\e]P47aa2f7"; echo -en "\e]P5bb9af7"
  echo -en "\e]P67dcfff"; echo -en "\e]P7a9b1d6"; echo -en "\e]P8414868"
  echo -en "\e]P9f7768e"; echo -en "\e]PA9ece6a"; echo -en "\e]PBe0af68"
  echo -en "\e]PC7aa2f7"; echo -en "\e]PDbb9af7"; echo -en "\e]PE7dcfff"
  echo -en "\e]PFc0caf5"
  echo -en "\033[0m"
  clear
} >/dev/tty # not into the install log, which stdout is copied to by then

mkdir -p /var/log
touch "$OMARCHY_INSTALL_LOG_FILE"

export COLUMNS=$(tput cols)
export LINES=$(tput lines)
exec > >(tee >(sed -u -E 's/\x1b(\[[0-9;?]*[A-Za-z]|[78])//g' >>"$OMARCHY_INSTALL_LOG_FILE") 2>/dev/null) 2>/dev/tty
export CLICOLOR_FORCE=1
export FORCE_COLOR=1

if [[ ${OMARCHY_INSTALL_DEBUG:-} == "1" ]]; then
  echo "=== Omarchy ISO debug build ==="
  [[ -f /usr/share/omarchy-iso/build-info ]] && cat /usr/share/omarchy-iso/build-info
  pacman -Q omarchy-settings omarchy-keyring 2>/dev/null || true
  echo "================================"
fi

# Warm the page cache for the root image and bundled packages while the user
# works through the wizard. The install writes a multi-GB root image to the
# target and then pacstraps a few packages out of the offline mirror; on media
# slower than the target the install is read-bound and every byte cached here
# is a byte it never waits for. On faster media this costs nothing but
# otherwise-idle bandwidth: the medium is untouched while the user types, and
# the target disk it writes to later is a different device.
#
# Clean page cache only, so the kernel reclaims it under pressure instead of
# OOMing, and a budget so small machines never evict what was just warmed.
# Set OMARCHY_NO_PREFETCH=1 to A/B the same ISO with this disabled.
warm_offline_mirror() {
  local mirror=/var/cache/omarchy/mirror/offline
  local mem_avail_kb half_kb headroom_kb budget_kb spent_kb=0 size_kb path
  # The orchestrator's ROOT_IMAGE.
  local image=/run/archiso/bootmnt/arch/$(uname -m)/omarchy-root.img.zst

  [[ ${OMARCHY_NO_PREFETCH:-} == 1 ]] && return 0

  # Keep at least 2 GiB free (or half of MemAvailable when MemAvailable <= 4 GiB)
  # so an 8 GiB machine can hold the full ~4 GiB root image warm in clean page
  # cache while small machines still avoid evicting what verify just cached.
  mem_avail_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
  half_kb=$((mem_avail_kb / 2))
  headroom_kb=$((mem_avail_kb - 2097152))
  budget_kb=$((headroom_kb > half_kb ? headroom_kb : half_kb))
  ((budget_kb > 262144)) || return 0

  # omarchy-mirror-verify.service and then omarchy-root-image-verify.service
  # (started at boot) read the shipped mirror and the whole image as they hash
  # them, and two readers on one USB stick seek against each other: let both
  # finish first, whatever their verdict. Wait on their start jobs, not on
  # is-active: while the mirror is hashed the image's job is queued behind it
  # (Before=) and that unit still reads inactive. The image's pass is the
  # warm-up for the image too; the read below then keeps it cached.
  while [[ -n $(systemctl list-jobs --no-legend omarchy-mirror-verify.service \
    omarchy-root-image-verify.service 2>/dev/null) ]]; do
    sleep 1
  done

  # The image first, and only when all of it fits: a second read of pages
  # the verify just cached keeps them cached through the install. When it does
  # not fit, leave the cache alone. omarchy-image-write writes whatever part
  # of the image is still cached first and reads the rest once; re-reading
  # the head here, or the mirror after it, would only evict the part the
  # verify left behind (on a 4 GB machine, most of what was cached).
  if [[ -f $image ]]; then
    size_kb=$(du -k -- "$image" | cut -f1)
    ((size_kb > budget_kb)) && return 0
    cat -- "$image" >/dev/null 2>&1 || true
    spent_kb=$size_kb
  fi

  [[ -d $mirror ]] || return 0

  # Then the mirror, largest first: when the budget cannot cover all of it
  # this still front-loads the bytes that dominate.
  while read -r size_kb path; do
    ((spent_kb + size_kb > budget_kb)) && continue
    cat -- "$path" >/dev/null 2>&1 || true
    spent_kb=$((spent_kb + size_kb))
  done < <(du -k "$mirror"/*.pkg.tar.zst 2>/dev/null | sort -rn)
}

# Inside kmscon the tty1 run is still warming the cache.
if [[ ${OMARCHY_KMSCON:-} != 1 ]]; then
  warm_offline_mirror &
  warm_pid=$!
  trap 'kill "$warm_pid" 2>/dev/null; printf "\e[?25h" >/dev/tty1 2>/dev/null' EXIT
fi

cd /root
# Autoinstall: a cidata drive carrying the configurator's own output files
# stands in for the wizard. omarchy-cidata-load copies them into /root and
# everything downstream runs the ordinary path against ordinary inputs.
# A rerun from the shell an abort left: the first run's mark that it ended
# would stand for this one too, and a kmscon that died under it would pass
# for an installer that finished. This run leaves its own, when it ends by
# itself, wizard or cidata install alike: kmscon dying hangs it up, and that
# is no ending to record.
if [[ -n ${OMARCHY_KMSCON_SHELL:-} && -n ${OMARCHY_KMSCON_ENDED:-} ]]; then
  rm -f "$OMARCHY_KMSCON_ENDED"
  trap 'printf "%s\n" "$?" >"$OMARCHY_KMSCON_ENDED"' EXIT
  trap 'trap - EXIT HUP TERM; kill -HUP $$' HUP TERM
fi
if [[ -f /usr/share/omarchy-iso/oem-install ]]; then
  export OMARCHY_UI_INTERACTIVE=no
  set_tokyo_night_colors
  ./configurator --oem
elif [[ ${OMARCHY_KMSCON:-} != 1 || -n ${OMARCHY_KMSCON_SHELL:-} ]] && /usr/local/bin/omarchy-cidata-load; then
  # Looked for by the tty1 run and by a rerun from the shell an abort left,
  # where a cidata drive may have been plugged in since. Not by the run kmscon
  # starts: the tty1 run that started it has just looked. The palette is the
  # console's to set; kmscon has its own.
  [[ ${OMARCHY_KMSCON:-} == 1 ]] || set_tokyo_night_colors
  echo "Autoinstall configuration found on cidata drive; skipping the configurator."
  export OMARCHY_UI_INTERACTIVE=no
elif [[ ${OMARCHY_KMSCON:-} == 1 ]]; then
  ./configurator && status=0 || status=$?
  ((status == 0)) || exit "$status"
else
  # The wizard and the whole install run in kmscon, which runs this script
  # again: fonts with every script the installer speaks, the same on every
  # machine, where the console has one bitmap font and cannot draw Chinese,
  # Japanese or Korean at all. The launcher is the runtime's own, the one
  # first-boot owner setup is drawn with.
  # shellcheck disable=SC1091
  source /usr/share/omarchy-iso/setup-form.sh
  # shellcheck disable=SC1091
  source /usr/share/omarchy-iso/kmscon.sh
  # shellcheck disable=SC1091
  source /usr/share/omarchy-iso/kmscon-session.sh

  # The answers a relaunch carries hold the password: however this run ends,
  # none outlive it.
  trap 'kill "$warm_pid" 2>/dev/null || true; rm -f "$KMSCON_RESUME"*; printf "\e[?25h" >/dev/tty1 2>/dev/null' EXIT

  # Before any language is picked, the one an ISO presets (presets/<code>.json).
  language=$(jq -r '.language // empty' /usr/share/omarchy-iso/preset.json 2>/dev/null || true)
  kmscon_session "$language" /bin/bash -c "$(kmscon_command)" _ /root/.automated_script.sh
  # The installer ran to its end in kmscon.
  exit 0
fi

# Deferred-provisioning installs skip the celebration/reboot prompt and reboot on
# their own — the owner completes setup at first boot. Signalled by the config's
# defer_provisioning flag (interactive) or the defer-provisioning marker (cidata).
# Parse the flag with jq (the same JSON semantics the orchestrator uses) rather
# than a line regex, so a reformatted config can't read as a direct install.
if [[ -f /root/defer-provisioning ]] ||
  [[ "$(jq -r '.omarchy_install.defer_provisioning // false' /root/user_configuration.json 2>/dev/null)" == "true" ]]; then
  export OMARCHY_UI_DEFER_PROVISIONING=yes
fi

# The dashboard speaks the language picked in the configurator, or named by an
# autoinstall configuration.
OMARCHY_ISO_LANGUAGE="$(jq -r '.omarchy_install.language // "en"' /root/user_configuration.json 2>/dev/null || echo en)"
export OMARCHY_ISO_LANGUAGE

# The foreground dashboard is now the sole visible install UI owner. It starts
# the actual installer as a non-interactive child, logs child output, waits for
# completion, then renders the final installed-time/reboot prompt itself.
export OMARCHY_DASHBOARD_TTY="$(tty)"
rm -f /run/omarchy-install/state.json
/usr/local/bin/omarchy-install-dashboard \
  "$OMARCHY_INSTALL_LOG_FILE" \
  /run/omarchy-install/state.json \
  -- \
  /usr/local/bin/omarchy-iso-install \
    --config /root/user_configuration.json \
    --creds /root/user_credentials.json \
    --encrypt-file /root/user_encrypt_installation.txt \
    --authorized-keys-file /root/authorized_keys \
    --tailscale-authkey-file /root/tailscale_authkey \
    --defer-provisioning-file /root/defer-provisioning \
    --oem-dir /usr/share/omarchy-iso/oem
