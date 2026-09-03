# shellcheck shell=bash
# Command execution helpers. Port of the parts of lib/command.py (SysCommand)
# that the installer uses: run a command, keep its output in the log, and
# optionally stream it to the terminal (peek_output).

# Run a command, capturing stdout+stderr into the log. Returns the command's
# exit status; the captured output is also left in SYS_CMD_OUTPUT.
SYS_CMD_OUTPUT=''
sys_cmd() {
  local rc=0
  debug "+ $*"
  SYS_CMD_OUTPUT=$("$@" 2>&1) || rc=$?
  [[ -n $SYS_CMD_OUTPUT ]] && _log_write CMD "$SYS_CMD_OUTPUT"
  return $rc
}

# Run a command with its output streamed to the terminal as well as the log
# (SysCommand(peek_output=True)).
sys_cmd_peek() {
  # `local -` scopes the option change to this function (bash ≥ 4.4); with
  # pipefail the status is the command's, since tee does not fail.
  local - rc=0
  set -o pipefail
  debug "+ $*"
  "$@" 2>&1 | tee -a "$ARCHINSTALL_LOG_FILE" || rc=$?
  return $rc
}

# Run a command with stdin fed from $1 (run(cmd, input_data=...)).
sys_cmd_input() {
  local input=$1 rc=0
  shift
  debug "+ $* (with stdin)"
  SYS_CMD_OUTPUT=$(printf '%s' "$input" | "$@" 2>&1) || rc=$?
  [[ -n $SYS_CMD_OUTPUT ]] && _log_write CMD "$SYS_CMD_OUTPUT"
  return $rc
}

# Installer.arch_chroot(): run a command inside the target.
chroot_cmd() {
  sys_cmd arch-chroot -S "$INST_TARGET" "$@"
}

chroot_cmd_peek() {
  sys_cmd_peek arch-chroot -S "$INST_TARGET" "$@"
}

# arch_chroot(cmd, run_as=user)
chroot_cmd_as() {
  local user=$1
  shift
  sys_cmd arch-chroot -S "$INST_TARGET" su - "$user" -c "$*"
}

# lib/models/users.py Password(plaintext): hash with yescrypt (what
# crypt_yescrypt() produces), falling back to sha512-crypt where mkpasswd is
# unavailable.
password_hash() {
  local plaintext=$1
  if command -v mkpasswd >/dev/null 2>&1; then
    printf '%s\n' "$plaintext" | mkpasswd --method=yescrypt --stdin
  else
    printf '%s\n' "$plaintext" | openssl passwd -6 -stdin
  fi
}

# Membership test for space-separated lists: list_contains "a b c" b
# Defined only when the embedder has not already provided it (the same
# define-if-missing contract as info/error in log.sh).
if ! declare -F list_contains >/dev/null; then
  list_contains() {
    local needle=$2 item
    for item in $1; do
      [[ $item == "$needle" ]] && return 0
    done
    return 1
  }
fi

# Path('/mnt/x').relative_to(anchor) → 'mnt/x'
relative_path() {
  local p=${1#/}
  printf '%s' "$p"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command missing: $c"
  done
}
