# shellcheck shell=bash
# Logging. Port of lib/log.py: human-readable lines on stdout/stderr, everything
# (including captured command output) appended to the install log.

ARCHINSTALL_LOG_DIR=${ARCHINSTALL_LOG_DIR:-/var/log/archinstall}
ARCHINSTALL_LOG_FILE=${ARCHINSTALL_LOG_FILE:-$ARCHINSTALL_LOG_DIR/install.log}
ARCHINSTALL_DEBUG=${ARCHINSTALL_DEBUG:-0}

log_init() {
  # stderr is silenced before the file redirection so a refused open (an
  # unprivileged caller) does not print before it takes effect.
  if ! mkdir -p "$ARCHINSTALL_LOG_DIR" 2>/dev/null || ! : 2>/dev/null >>"$ARCHINSTALL_LOG_FILE"; then
    ARCHINSTALL_LOG_FILE=/dev/null
  fi
}

_log_write() {
  local level=$1
  shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$ARCHINSTALL_LOG_FILE" 2>/dev/null || true
}

debug() {
  _log_write DEBUG "$*"
  [[ $ARCHINSTALL_DEBUG == 1 ]] && printf 'debug: %s\n' "$*" >&2
  return 0
}

# info and error belong to whoever embeds the library: Omarchy's orchestrator
# defines its own before this file loads (its dashboard owns their shape and
# captures stdout into its install log). The versions here are the standalone
# fallback, defined only when nobody got there first.
if ! declare -F info >/dev/null; then
  info() {
    _log_write INFO "$*"
    printf '%s\n' "$*"
  }
fi

warn() {
  _log_write WARNING "$*"
  printf 'warning: %s\n' "$*" >&2
}

if ! declare -F error >/dev/null; then
  error() {
    _log_write ERROR "$*"
    printf 'error: %s\n' "$*" >&2
  }
fi

# Fatal error. archinstall raises an exception here; the bash equivalent is to
# exit. A sourcing orchestrator that wants to survive a failed step should run
# it in a subshell, or set ARCHINSTALL_ON_DIE to a function to call first.
die() {
  error "$*"
  if [[ -n ${ARCHINSTALL_ON_DIE:-} ]] && declare -F "$ARCHINSTALL_ON_DIE" >/dev/null; then
    "$ARCHINSTALL_ON_DIE" "$*"
  fi
  exit 1
}
