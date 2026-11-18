#!/bin/bash
#
# center() lays out the install dashboard's text: three lines a frame, ten
# frames a second, for the whole install, while pacstrap wants every cycle.
# These pin the bytes it prints and that it starts no program but the stty
# that reads the console size: the sed and the subshells it used to start on
# every call cost the dashboard close to half of its CPU time.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The dashboard runs as a program, so take its colours and its function
# definitions without running anything else in it.
eval "$(sed -n '/^CSI=/,/^RED=/p' "$DASHBOARD")"
eval "$(sed -n '/^[a-z_]*() {$/,/^}$/p; /^[a-z_]*() { .*; }$/p' "$DASHBOARD")"
declare -F center >/dev/null || fail "the dashboard defines center()"
TTY_PATH=/dev/null
CONTENT_WIDTH=81

# stty answers with the console size the case asks for, or fails like it does
# off a terminal; both stubs write down every call.
stubs="$work/bin"
mkdir -p "$stubs"
cat >"$stubs/stty" <<'STUB'
#!/bin/bash
printf 'stty %s parent %s\n' "$*" "$PPID" >>"$STUB_LOG"
[[ $1 == size && $STUB_COLS != fail ]] || exit 1
printf '24 %s\n' "$STUB_COLS"
STUB
cat >"$stubs/sed" <<STUB
#!/bin/bash
printf 'sed\n' >>"\$STUB_LOG"
exec $(command -v sed) "\$@"
STUB
chmod +x "$stubs/stty" "$stubs/sed"
export STUB_LOG="$work/calls" STUB_COLS=80
PATH="$stubs:$PATH"
export LC_ALL=C.UTF-8

# expect <description> <console columns> <text> <width> <spaces> <shown>
# spaces: every column before the text, both paddings; shown: what %b prints.
expect() {
  local description="$1" cols="$2" text="$3" width="$4" spaces="$5" shown="$6"

  STUB_COLS=$cols
  center "$text" "$width" >"$work/got"
  printf '\r%s%*s%s%s\n' "$CLEAR_LINE" "$spaces" '' "$shown" "$RESET" >"$work/want"
  cmp -s "$work/want" "$work/got" ||
    fail "$description" "$(diff <(od -c "$work/want") <(od -c "$work/got") || true)"
  pass "$description"
}

# The progress screen: PROGRESS_TEXT_WIDTH is the console less two, at most
# the logo's 81. Colours take no columns.
expect "the percentage centers in the text width, colours not counted" \
  80 "${GREEN}42%${RESET}" 78 38 "${GREEN}42%${RESET}"
expect "a wide console adds its own margin" \
  120 "${GREEN}curating cohesive colors${RESET}" 81 47 "${GREEN}curating cohesive colors${RESET}"
expect "nothing to show still clears the line" \
  80 "" 81 40 ""
expect "a block wider than the console sits flush left" \
  40 "Installed Omarchy in 12m 34s" 81 26 "Installed Omarchy in 12m 34s"
expect "an unreadable console size counts as 80 columns" \
  fail "Omarchy" 40 36 "Omarchy"

# truncate_for_width ends a cut line with an ellipsis: one character, three
# bytes, counted the way the locale counts it.
expect "a multibyte character is one column in a UTF-8 locale" \
  81 "${GREEN}polishing pretty pixels…${RESET}" 81 28 "${GREEN}polishing pretty pixels…${RESET}"
export LC_ALL=C
expect "the C locale counts its bytes" \
  81 "${GREEN}polishing pretty pixels…${RESET}" 81 27 "${GREEN}polishing pretty pixels…${RESET}"
export LC_ALL=C.UTF-8

# Only CSI sequences are left out of the length; others are counted.
expect "cursor and erase sequences take no columns" \
  10 "${CSI}2K${CSI}?25l${CSI}10;5Hab${RESET}" 10 4 "${CSI}2K${CSI}?25l${CSI}10;5Hab${RESET}"
expect "an OSC sequence is counted like text" \
  11 $'\e]0;t\ax' 11 2 $'\e]0;t\ax'

# Failure text comes from the state file and the log, and center() prints it
# with %b: backslash sequences are expanded before they are measured.
expect "backslash sequences are expanded, then measured" \
  81 'C:\new\temp' 81 36 $'C:\new\temp'

STUB_COLS=80
[[ $(left_padding 40) == "$(printf '%20s' '')" ]] ||
  fail "left_padding still prints the margin" "got: '$(left_padding 40)'"
pass "left_padding still prints the margin"

# PATH holds the stubs alone, so any other program would fail on stderr, and
# the log names each stub call. stty's parent must be the shell that called
# center(): a subshell around the size read would sit in between.
check_programs() {
  local text="$1" width="$2"
  local -a calls

  : >"$STUB_LOG"
  (PATH="$stubs"; printf 'caller %s\n' "$BASHPID" >>"$STUB_LOG"; center "$text" "$width") >/dev/null 2>"$work/stderr"
  [[ ! -s $work/stderr ]] ||
    fail "center() runs no other program: $(cat -v <<<"$text")" "$(cat "$work/stderr")"
  mapfile -t calls <"$STUB_LOG"
  (( ${#calls[@]} == 2 )) && [[ ${calls[1]} == "stty size parent ${calls[0]#caller }" ]] ||
    fail "center() runs stty once, from its own shell, and nothing else: $(cat -v <<<"$text")" "$(<"$STUB_LOG")"
}

STUB_COLS=80
check_programs "${GREEN}42%${RESET}" 78
check_programs "${GREEN}curating cohesive colors${RESET}" 78
check_programs "${DIM}Tip: Super + K shows all the key bindings${RESET}" 78
check_programs "${RED}Omarchy installation stopped${RESET}" "$CONTENT_WIDTH"
check_programs "Installer exited with status 1" "$CONTENT_WIDTH"
pass "center() starts stty once per call, from its own shell, and no other program"
