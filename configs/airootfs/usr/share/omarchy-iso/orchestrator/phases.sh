# shellcheck shell=bash
# The install's phase state IS the systemd unit graph: the phase units
# latch (RemainAfterExit=yes), so systemd's own records -- ActiveState,
# Result, StatusText and the ExecMain timestamps -- say who is running, who
# finished, who failed and how long everything took. The dashboard polls
# `systemctl show` for all of it; nothing writes a parallel document. What
# lives here is the rest: in-phase progress published over sd_notify, and
# the timing record the finished install keeps.

# The unit files are the roster (a phase unit is exactly a unit whose
# ExecStart runs run-phase); tests point this at a fixture directory.
phase_units_dir() {
  printf '%s' "${OMARCHY_INSTALL_UNITS_DIR:-/etc/systemd/system}"
}

# Phases that can measure themselves (the root image unpack, the verify
# wait) publish their fraction (0..1) as the unit's sd_notify STATUS=,
# which the dashboard reads back as the unit's StatusText. NotifyAccess=all
# on the phase units accepts the message from any process in the phase's
# cgroup -- the watcher subshells included -- and STATUS= never touches the
# oneshot's latch (only READY= would). Best effort: progress display must
# never fail an install.
phases_write_progress() {
  local fraction=$1
  [[ $fraction =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  NOTIFY_SOCKET="${NOTIFY_SOCKET:-/run/systemd/notify}" \
    systemd-notify --status="progress=$fraction" 2>/dev/null || true
}

# One TSV row per phase unit that ran, for the timing record:
# start-monotonic-us, display name, ok|failed, elapsed seconds. The display
# name is run-phase's second ExecStart argument -- the same place the
# dashboard reads it from.
phases_timing_rows() {
  local unit_file unit name line state result start_us exit_us
  for unit_file in "$(phase_units_dir)"/omarchy-install-*.service; do
    line=$(grep -m1 -E '^ExecStart=.*run-phase ' "$unit_file" 2>/dev/null) || continue
    unit=${unit_file##*/}
    name=${line#*run-phase *\"}
    name=${name%%\"*}
    {
      read -r state
      read -r result
      read -r start_us
      read -r exit_us
    } < <(systemctl show "$unit" \
      -p ActiveState,Result,ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic \
      --value 2>/dev/null)
    [[ ${start_us:-0} =~ ^[0-9]+$ ]] && ((start_us > 0)) || continue
    [[ ${exit_us:-0} =~ ^[0-9]+$ ]] || exit_us=0
    printf '%s\t%s\t%s\t%s\n' "$start_us" "$name" \
      "$([[ $state == failed || $result != success ]] && echo failed || echo ok)" \
      "$(awk -v s="$start_us" -v e="$exit_us" 'BEGIN { printf "%.3f", (e > s ? e - s : 0) / 1000000 }')"
  done
}

# Orchestrator, after the graph completes: the timing copy the installed
# system keeps, generated from systemd's own timestamps, plus expected vs
# actual package counts so drift is visible in acceptance runs rather than
# only by watching a bar creep.
phases_finalize() {
  local timing="$CTX_TARGET/var/log/omarchy-install-timing.json"
  mkdir -p "${timing%/*}"
  phases_timing_rows | sort -n | jq -Rs \
    --argjson installed "$(installed_package_count "$CTX_TARGET")" \
    --argjson expected "$(expected_package_count)" \
    --arg finished "$(date '+%s.%N')" '
    {finished_at: ($finished | tonumber),
     installed_packages: $installed, expected_packages: $expected,
     phases: [split("\n")[] | select(length > 0) | split("\t")
              | {name: .[1], status: .[2], elapsed: (.[3] | tonumber)}]}' \
    >"$timing"

  export_install_journal "$CTX_TARGET/var/log/omarchy-install.log"
}

# The phases' own output lives in the journal, timestamped -- something the
# flat log never had. Appended to a log file at the two ends an install can
# reach: onto the installed system at finalize, and onto the live session
# log when the install fails, so "Upload log for support" and the media
# diagnosis see the failing phase's words and not just the headline. Every
# unit with omarchy in its name, not only the phases: the verifies, the
# prefetch, the pacman sync and the keyring unit are the install's
# supporting cast, and a failure often starts in one of them. Every mount
# unit too: the install mounts and unmounts constantly (stage binds, the
# subvolume swap, the chroots' namespaces) and systemd's record of those is
# where "target is busy" gets its explanation. Two queries: -u and -t do not
# compose in one (measured on the phase-error handover). Stage 2, parked: a
# JSON companion export (-o json) for field-level debugging.
export_install_journal() {
  local dest=$1
  {
    printf '\n=== install journal (*omarchy* and *.mount units) ===\n'
    journalctl -b -u '*omarchy*' -u '*.mount' -o short-iso --no-pager 2>/dev/null |
      sed -f "${ORCHESTRATOR_DIR:-/usr/share/omarchy-iso/orchestrator}/log-filter.sed"
    journalctl -b -t omarchy-phase-error -t omarchy-install-milestone -o short-iso --no-pager 2>/dev/null
  } >>"$dest" || true
}

# _installed_package_count(): one directory per package under local/, which
# is what the dashboard counts live.
installed_package_count() {
  local local_db="$1/var/lib/pacman/local" n=0 entry
  [[ -d $local_db ]] || { printf 0; return 0; }
  for entry in "$local_db"/*/; do
    [[ -d $entry ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}

expected_package_count() {
  local n
  n=$(awk 'NR == 1 { print $1; exit }' /usr/share/omarchy-iso/expected-packages 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}
