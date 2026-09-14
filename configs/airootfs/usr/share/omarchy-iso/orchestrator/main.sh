#!/usr/bin/env bash
#
# Omarchy install orchestrator.
#
# Single tool that owns the full install phase ordering, with archinstall-bash
# used as a library subsystem (not as the top-level installer). The live-ISO
# wrapper (omarchy-iso-install) consumes CLI args and passes configuration
# paths via OMARCHY_INSTALL_* environment variables.
#
# The phases run as systemd units (run-phase hosts each function in the
# unit's own process); this process seeds the dashboard state, starts the
# graph's terminal unit, and finalizes. Its EXIT trap does what the Python
# orchestrator's finally did — record a failure no phase could, restore CPU
# governors and hook masks, stop the install target (the group abort), tear
# down a protected target.

set -eEuo pipefail

ORCHESTRATOR_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# ui.sh before the library, structurally: the orchestrator's info, error and
# list_contains must be the definitions in effect (the dashboard log relies
# on their shape), and the library defines its own only when none exist —
# so precedence is a define-if-missing contract, not source-order luck.
# shellcheck disable=SC1090
source "$ORCHESTRATOR_DIR/ui.sh"
OMARCHY_ARCHINSTALL_LIB=${OMARCHY_ARCHINSTALL_LIB:-/usr/share/archinstall-bash/lib}
if [[ ! -f $OMARCHY_ARCHINSTALL_LIB/archinstall.sh ]]; then
  printf 'error: archinstall-bash missing at %s\n' "$OMARCHY_ARCHINSTALL_LIB" >&2
  exit 2
fi
# shellcheck disable=SC1091
source "$OMARCHY_ARCHINSTALL_LIB/archinstall.sh"
for _module in context phases archinstall root_image install limine target_setup provisioning lifecycle; do
  # shellcheck disable=SC1090
  source "$ORCHESTRATOR_DIR/$_module.sh"
done
unset _module

# Phase order. The ordering was the whole point of this orchestrator, and it
# now lives where systemd can walk it: every phase is a unit under
# /etc/systemd/system/omarchy-install-*.service, each Requires= and After=
# its predecessor, and starting the terminal unit pulls the whole chain in
# order. The invariants the old loop's comments carried still hold by those
# edges: package-install hooks (limine-mkinitcpio-hook, in particular) and
# useradd happen at points where their prerequisites are in place, and the
# deferred-provisioning cryptkey staging precedes the final UKI build.
#
# Full-disk and protected installs walk the same graph. The configurator
# only changes the JSON input: full-disk asks the installer to create/mount
# the layout, while protected provides an already-mounted target and the
# partition details Omarchy needs for boot/fstab generation.
PHASE_GRAPH_TERMINAL=omarchy-install-factory-snapshot.service

# The failed phase's own words, for the failure headline: fail() in the
# phase's process handed them to the journal under their own identifier;
# the plain unit stream (where they sit buried under command output and
# systemd's exit lines) is the fallback.
phase_graph_failure_detail() {
  local failed_unit=$1 detail
  # The unit key is a line prefix, not a journald field: the writer's
  # cgroup is gone before attribution resolves (see run-phase), so the
  # identifier finds the entries and the prefix picks this unit's out.
  detail=$(journalctl -b -t omarchy-phase-error -o cat --no-pager 2>/dev/null |
    sed -n "s/^$failed_unit: //p") || true
  [[ -n $detail ]] ||
    detail=$(journalctl --no-pager -o cat -b -u "$failed_unit" 2>/dev/null | tail -n 5 | tr '\n' ' ')
  printf '%s' "$detail"
}

main() {
  ctx_from_env

  local who=$CTX_USERNAME
  [[ -n $who ]] || who='deferred provisioning (user created at first boot)'
  info "Installing Omarchy for $who → $CTX_TARGET"
  # The span the user experiences, marked in the journal: this process
  # starts the moment the configurator hands over, and the finish marker
  # lands once the graph completes. The dashboard reads the pair back by
  # identifier (epoch stamps via -o short-unix) for its installed-in line.
  printf '%s\n' '-----BEGIN OMARCHY INSTALL-----' | systemd-cat -t omarchy-install-milestone 2>/dev/null || true

  # The umbrella for the systemd-run phases: parts declare PartOf= it, so
  # stopping it is the group abort that takes any running phase's cgroup.
  # Starting it also pulls the CPU boost unit (the target's Wants=), whose
  # ExecStop restores the governors when the target stops.
  systemctl start omarchy-install.target >/dev/null 2>&1 || true

  trap 'orchestrator_on_err "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
  trap orchestrator_on_exit EXIT
  trap orchestrator_on_interrupt INT TERM

  arch_init_library
  mkdir -p "$CTX_STATE_DIR"
  # A stale handoff from an aborted earlier attempt in the same session
  # must not leak into this run. (The error handover needs no cleanup: it
  # lives in the journal, boot-scoped and read per failed unit.)
  rm -f "$CTX_STATE_DIR/library-state.sh"

  # One blocking start of the terminal phase: its Requires=/After= chain
  # pulls every phase in order; the latched units themselves are the record
  # the dashboard polls. A failed phase fails its start job and the chain
  # stops there -- collect the phase's own words from their journal entry.
  local failed_unit
  if ! systemctl start "$PHASE_GRAPH_TERMINAL"; then
    failed_unit=$(systemctl list-units --failed --plain --no-legend 'omarchy-install-*' 2>/dev/null |
      awk '{print $1; exit}')
    fail "install phase ${failed_unit:-graph} failed: $(phase_graph_failure_detail "${failed_unit:-$PHASE_GRAPH_TERMINAL}")"
  fi

  # The END marker lands before the finalize so the journal copy it exports
  # onto the target carries both ends of the span.
  printf '%s\n' '-----END OMARCHY INSTALL-----' | systemd-cat -t omarchy-install-milestone 2>/dev/null || true
  phases_finalize

  ORCH_SUCCESS=true
  info 'Installation complete.'
}

# Executed (omarchy-iso-install execs this file): run the install. Sourced
# (run-phase, which hosts one phase function in its own process for the
# systemd phase units): definitions only.
[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
