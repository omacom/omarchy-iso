# The installer's kmscon session on tty1, and the answers the configurator
# carries across a kmscon relaunch. Sourced by .automated_script.sh and the
# configurator.
#
# kmscon takes its keyboard layout and font once, at its start. To change
# either, the configurator saves the answers so far, password included, to
# kmscon-resume and exits 75; the tty1 run starts kmscon again, and the
# configurator inside it takes the answers back. The file holds the password,
# so it is written only for a tty1 run that is waiting to start kmscon again,
# taken back only under one, and removed by that run however it ends.
#
#   kmscon_session <language> <command...>
#       tty1: run command in kmscon until it ends without asking for a
#       relaunch, starting kmscon again for as long as it dies under the
#       command: the installer is drawn in kmscon and nowhere else
#   kmscon_save_answers <variable...>
#       configurator: save the variables for the relaunch; 1 outside a session
#   kmscon_take_answers
#       configurator: print the saved answers, as declare statements, and
#       remove them; 1 when there are none

KMSCON_RUN_DIR=${KMSCON_RUN_DIR:-/run/omarchy-iso}
KMSCON_RESUME=$KMSCON_RUN_DIR/kmscon-resume
# The command run in kmscon writes its exit status here once it ends, so a
# kmscon that ended without it died under the command.
KMSCON_ENDED=$KMSCON_RUN_DIR/kmscon-ended

kmscon_session() {
  local language=$1 keymap start_language
  shift
  mkdir -p "$KMSCON_RUN_DIR"
  chmod 700 "$KMSCON_RUN_DIR"
  # A file left by anything before this run is not its answers.
  rm -f "$KMSCON_RESUME"* "$KMSCON_ENDED"
  export OMARCHY_KMSCON_SUPERVISOR=$BASHPID OMARCHY_KMSCON_ENDED=$KMSCON_ENDED

  while true; do
    keymap=us start_language=$language
    if [[ -r $KMSCON_RESUME ]]; then
      { read -r keymap; read -r start_language; } < <(bash -c 'source "$1"; printf "%s\n%s\n" "${keyboard:-us}" "${language:-}"' _ "$KMSCON_RESUME")
    fi
    rm -f "$KMSCON_ENDED"
    omarchy_kmscon "$KMSCON_RUN_DIR/kmscon.log" "$keymap" "$start_language" "" "$@"

    if [[ ! -e $KMSCON_ENDED ]]; then
      # kmscon died under the command. Answers not yet taken back are run
      # again; answers taken back are lost with the run that held them, and
      # the installer starts over. The pause keeps a kmscon that cannot start
      # from spinning.
      echo "kmscon ended before the installer did; starting it again." >&2
      sleep "${KMSCON_RETRY_PAUSE:-1}"
      continue
    fi
    # The relaunch the configurator asked for.
    [[ -e $KMSCON_RESUME ]] && continue
    return 0
  done
}

# The command kmscon runs: the installer, recording how it ended. It exits 75
# to ask for a relaunch; anything else that is not success leaves a shell in
# kmscon, so an abort's message stays readable and the installer can be rerun
# in its language. The shell keeps this PID, so a rerun from it that asks for
# a relaunch can hang it up, which ends kmscon. Ctrl+C reaches this command
# along with the installer it interrupts: caught here, so it still records the
# ending and leaves that shell, where dying of it would pass for kmscon dying
# and start the installer over.
kmscon_command() {
  printf '%s' 'trap : INT; "$@"; status=$?; printf "%s\n" "$status" >"$OMARCHY_KMSCON_ENDED"; ((status == 0 || status == 75)) && exit $status; trap - INT; export OMARCHY_KMSCON_SHELL=$$; exec bash -l'
}

kmscon_supervised() {
  [[ -n ${OMARCHY_KMSCON_SUPERVISOR:-} ]] && kill -0 "$OMARCHY_KMSCON_SUPERVISOR" 2>/dev/null
}

kmscon_save_answers() {
  local tmp
  # Run by hand on another VT, nothing would start kmscon again and take the
  # answers back: save nothing.
  kmscon_supervised || return 1
  # Written whole under another name, then renamed: a run killed midway leaves
  # no half a file, and a file already there with looser permissions is
  # replaced, not rewritten.
  tmp=$(umask 077 && mktemp "$KMSCON_RESUME.XXXXXX") || return 1
  # declare -p fails for a name not set yet, still printing the rest.
  declare -p "$@" 2>/dev/null >"$tmp" || true
  if ! mv -f "$tmp" "$KMSCON_RESUME"; then
    rm -f "$tmp"
    return 1
  fi
  # The tty1 run may have ended, and cleaned up, between the check above and
  # the write: answers nobody is left to take back are removed here.
  if ! kmscon_supervised; then
    rm -f "$KMSCON_RESUME"
    return 1
  fi
  # A rerun from the shell an abort left: that shell, not kmscon's command,
  # would get the relaunch request, so end it to end kmscon.
  if [[ -n ${OMARCHY_KMSCON_SHELL:-} ]]; then
    kill -HUP "$OMARCHY_KMSCON_SHELL" 2>/dev/null || true
  fi
}

kmscon_take_answers() {
  local answers
  # Only the run tty1 started takes the answers back, not one by hand on
  # another VT.
  [[ -n ${OMARCHY_KMSCON_SUPERVISOR:-} && -r $KMSCON_RESUME ]] || return 1
  answers=$(<"$KMSCON_RESUME")
  rm -f "$KMSCON_RESUME"
  printf '%s\n' "$answers"
}
