#!/bin/bash
# The kmscon relaunch handoff, with a fake kmscon: the answers carried across a
# relaunch, password included, reach the next run and nothing else, and never
# outlive the session that wrote them.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export KMSCON_RETRY_PAUSE=0 KMSCON_RUN_DIR="$work/run" WORK="$work" SESSION="$ROOT/configs/airootfs/usr/share/omarchy-iso/kmscon-session.sh"
# shellcheck disable=SC1090
source "$SESSION"

fail() { echo "not ok - $*" >&2; exit 1; }

# The configurator kmscon runs, doing what the queue says for this run.
cat >"$work/configurator" <<'INNER'
#!/bin/bash
set -euo pipefail
source "$SESSION"
if answers=$(kmscon_take_answers); then eval "$answers"; fi
printf '%s\n' "${password:-none}" >>"$WORK/seen"
case $ACTION in
  save)
    password='s3cr"et' keyboard=jp106 language=ja
    kmscon_save_answers keyboard language password || exit 9
    stat -c %a "$KMSCON_RESUME" >>"$WORK/modes"
    exit 75 ;;
  finish) exit 0 ;;
  abort) exit 1 ;;
  crash) kill -9 "$PPID" ;; # kmscon dies, taking the command with it
  interrupt) kill -INT "$PPID" "$$" ;; # Ctrl+C reaches the command and the installer
esac
INNER

# Fake kmscon: one queued action per start; "die" dies before running anything.
omarchy_kmscon() {
  local keymap=$2 language=$3 action
  shift 4
  action=$(head -n1 "$work/queue"); sed -i 1d "$work/queue"
  printf '%s %s %s\n' "$action" "$keymap" "${language:--}" >>"$work/starts"
  [[ $action == die ]] && return 0
  ACTION=$action OMARCHY_KMSCON=1 "$@" </dev/null >>"$work/log" 2>&1 || true
}

run() {
  rm -f "$work/starts" "$work/seen" "$work/modes"
  printf '%s\n' "$@" >"$work/queue"
  (kmscon_session "" /bin/bash -c "$(kmscon_command)" _ bash "$work/configurator") && status=0 || status=$?
}
left() { compgen -G "$KMSCON_RUN_DIR/kmscon-resume*" >/dev/null; }

# A relaunch carries the answers to the next run, in the layout and language
# picked, then they are gone.
run save finish
((status == 0)) || fail "a finished install returns $status"
[[ $(<"$work/starts") == $'save us -\nfinish jp106 ja' ]] || fail "relaunch started with $(<"$work/starts")"
[[ $(<"$work/seen") == $'none\ns3cr"et' ]] || fail "the next run saw $(<"$work/seen")"
[[ $(<"$work/modes") == 600 ]] || fail "the answers were written with mode $(<"$work/modes")"
left && fail "the answers outlived a finished install"
echo "ok - a relaunch carries the answers, mode 600, and a finished install leaves none"

# An abort ends the session (its shell stays in kmscon) without answers left.
run save abort
((status == 0)) || fail "an abort returns $status"
left && fail "the answers outlived an abort"
echo "ok - an abort leaves no answers"

# kmscon dying before the relaunched run took the answers: started again with them.
run save die finish
[[ $(<"$work/seen") == $'none\ns3cr"et' ]] || fail "after a death the next run saw $(<"$work/seen")"
left && fail "the answers outlived a death before they were taken"
echo "ok - kmscon dying before the answers are taken starts it again with them"

# kmscon dying after the run took the answers: they died with it, start over.
run save crash finish
((status == 0)) || fail "a crash then finish returns $status"
[[ $(<"$work/seen") == $'none\ns3cr"et\nnone' ]] || fail "after a crash the runs saw $(<"$work/seen")"
left && fail "the answers outlived a crash"
echo "ok - kmscon dying after the answers are taken starts the installer over"

# Ctrl+C on a screen of the installer ends the installer, not the session:
# kmscon is not started again under the shell it leaves.
run interrupt
((status == 0)) || fail "an interrupted install returns $status"
[[ $(<"$work/starts") == "interrupt us -" ]] || fail "after Ctrl+C kmscon started with $(<"$work/starts")"
left && fail "the answers outlived an interrupted install"
echo "ok - Ctrl+C ends the installer without starting kmscon again"

# kmscon that keeps dying is started again each time, with the answers, until
# it holds: there is no console to hand the installer to.
run save die die die finish
((status == 0)) || fail "an install that finished after kmscon kept dying returns $status"
[[ $(<"$work/starts") == $'save us -\ndie jp106 ja\ndie jp106 ja\ndie jp106 ja\nfinish jp106 ja' ]] || fail "a kmscon that kept dying started with $(<"$work/starts")"
[[ $(<"$work/seen") == $'none\ns3cr"et' ]] || fail "after kmscon kept dying the run saw $(<"$work/seen")"
left && fail "the answers outlived a kmscon that kept dying"
echo "ok - a kmscon that keeps dying is started again with the answers until it holds"

# The tty1 run ending between the check and the write: the answers written
# for nobody are removed.
(
  export OMARCHY_KMSCON_SUPERVISOR=$BASHPID
  mkdir -p "$KMSCON_RUN_DIR"
  calls=0
  kmscon_supervised() { ((++calls == 1)); }
  password=x
  kmscon_save_answers password && fail "saved answers for a session that had ended"
  left && fail "answers written as the session ended were left behind"
  exit 0
)
echo "ok - answers written as the session ends are removed"

# A file planted before the session is not taken as its answers.
mkdir -p "$KMSCON_RUN_DIR"; echo 'password=planted' >"$KMSCON_RUN_DIR/kmscon-resume"
run finish
[[ $(<"$work/seen") == none ]] || fail "a stale file was taken: $(<"$work/seen")"
echo "ok - answers left from before the session are dropped"

# By hand on another VT, outside a session: nothing is saved or taken.
(
  unset OMARCHY_KMSCON_SUPERVISOR
  password=x
  kmscon_save_answers password && fail "saved answers outside a session"
  echo 'password=planted' >"$KMSCON_RESUME"
  kmscon_take_answers >/dev/null && fail "took answers outside a session"
  rm -f "$KMSCON_RESUME"
) || exit 1
# A session that is gone counts as none.
(
  export OMARCHY_KMSCON_SUPERVISOR=999999
  # shellcheck disable=SC2034 # the answer a live session would save, which a dead one must not
  password=x
  kmscon_save_answers password && fail "saved answers for a session that is gone"
  true
) || exit 1
left && fail "a run outside a session left answers"
echo "ok - a run by hand outside a session saves and takes no answers"
