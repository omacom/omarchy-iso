#!/bin/bash
#
# Every shell script in the repository passes shellcheck at warning level.
# bash -n accepts a script whose quotes end in the wrong place if the result
# still parses: an apostrophe in a comment once ended vm-seal's guest script,
# and the runner ran the rest itself. shellcheck reports where that happens.
#
# A shell script is a tracked file named *.sh, one whose #! line runs sh, bash,
# dash or ash, or one that starts with a "# shellcheck shell=" directive. The
# archiso submodule is upstream's and stays out. .shellcheckrc at the root
# makes shellcheck read the files the scripts source, all but those the build
# vendors or writes.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v shellcheck >/dev/null || fail "shellcheck is not installed"

git -C "$ROOT" rev-parse --git-dir >/dev/null || fail "the scripts are found with git ls-files; $ROOT is not a git checkout"
# The shell on the #! line, or the one env runs: /bin/bash -p, /usr/bin/env -S bash.
shebang='^#![[:space:]]*([^[:space:]]*/)?(env[[:space:]]+(-S[[:space:]]+)?([^[:space:]]*/)?)?(ba|da|a)?sh([[:space:]]|$)'
scripts=()
while IFS= read -r -d '' file; do
  [[ -f $ROOT/$file && ! -L $ROOT/$file ]] || continue
  first=""
  IFS= read -r first <"$ROOT/$file" || true
  if [[ $file == *.sh || $first =~ $shebang || $first == "# shellcheck shell="* ]]; then
    scripts+=("$file")
  fi
done < <(git -C "$ROOT" ls-files -z)
(( ${#scripts[@]} )) || fail "git ls-files found no shell scripts"

# One shellcheck takes 26 s for all of them on one core, two fifths of it
# reading base-test.sh again for each scenario that sources it. Each file is
# checked on its own either way, so they are spread over every core, one line
# per warning.
cd "$ROOT"
printf '%s\0' "${scripts[@]}" | xargs -0 -n 4 -P "$(nproc)" shellcheck -S warning -f gcc -- ||
  fail "shellcheck found problems in the shell scripts above"
echo "ok - shellcheck passes on ${#scripts[@]} shell scripts"
