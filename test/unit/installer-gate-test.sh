#!/bin/bash
#
# The partition guard in the configurator is only worth anything if the script
# that launches it honours a refusal. .automated_script.sh hands off to the
# install dashboard unconditionally once the wizard returns, so these cases
# pin the two gates that stand between: the configurator's exit status, and
# the configuration file it is supposed to have produced.
#
# The launcher is a tty1-gated monolith that redirects its own output and
# execs the real installer, so the handoff region is lifted out and run in a
# sandbox with /root, /usr/local/bin and /run rewritten to throwaway paths.
# The lines under test are the file's own, unmodified.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LAUNCHER="$ROOT/configs/airootfs/root/.automated_script.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# Rebuild the sandbox and the handoff script for each case. CIDATA_EXIT and
# CONFIGURATOR_EXIT drive which branch runs; CONFIGURATOR_WRITES_CONFIG says
# whether the wizard got far enough to leave a configuration behind.
new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/root" "$sandbox/bin" "$sandbox/run"

  cat >"$sandbox/bin/omarchy-cidata-load" <<'STUB'
#!/bin/bash
exit "${CIDATA_EXIT:-1}"
STUB

  cat >"$sandbox/root/configurator" <<'STUB'
#!/bin/bash
[[ ${CONFIGURATOR_WRITES_CONFIG:-0} == 1 ]] && echo '{"disk_config": {}}' >user_configuration.json
exit "${CONFIGURATOR_EXIT:-0}"
STUB

  # The marker is the whole assertion: if it exists, an install was started.
  cat >"$sandbox/bin/omarchy-install-dashboard" <<'STUB'
#!/bin/bash
touch "$SANDBOX/install-started"
STUB

  cat >"$sandbox/bin/jq" <<'STUB'
#!/bin/bash
echo false
STUB

  # tty is read for the dashboard's TTY handle; the test has no terminal.
  cat >"$sandbox/bin/tty" <<'STUB'
#!/bin/bash
echo /dev/console
STUB

  chmod +x "$sandbox/bin"/* "$sandbox/root/configurator"

  sed -n '/^cd \/root$/,$p' "$LAUNCHER" |
    sed -e "s#^cd /root\$#cd $sandbox/root#" \
      -e "s#/usr/local/bin/#$sandbox/bin/#g" \
      -e "s#/root/#$sandbox/root/#g" \
      -e "s#/run/omarchy-install/#$sandbox/run/#g" \
      >"$sandbox/handoff.sh"

  # The lift has to keep the pieces under test. A silent sed miss would turn
  # every case into a vacuous pass.
  grep -q 'configurator || exit 1' "$sandbox/handoff.sh" &&
    grep -q 'user_configuration.json \]\] || exit 1' "$sandbox/handoff.sh" &&
    grep -q "$sandbox/bin/omarchy-install-dashboard" "$sandbox/handoff.sh"
}

run_handoff() {
  SANDBOX="$sandbox" \
    OMARCHY_INSTALL_LOG_FILE="$sandbox/install.log" \
    PATH="$sandbox/bin:$PATH" \
    bash "$sandbox/handoff.sh" >/dev/null 2>&1
}

installed() {
  [[ -e $sandbox/install-started ]] && echo yes || echo no
}

echo "==> the handoff region is lifted intact"
new_sandbox
check "both gates and the dashboard handoff survive the rewrite" "0" "$?"

echo "==> a configurator that refuses does not start an install"
new_sandbox
CONFIGURATOR_EXIT=1 CONFIGURATOR_WRITES_CONFIG=0 run_handoff
check "the launcher exits nonzero" "1" "$?"
check "no install was started" "no" "$(installed)"

# The abort path tells the user to re-run the launcher. A configuration left
# by the run that just refused describes a partition layout the guard rejected.
echo "==> a stale configuration cannot stand in for a refused one"
new_sandbox
echo '{"disk_config": {}}' >"$sandbox/root/user_configuration.json"
CONFIGURATOR_EXIT=1 CONFIGURATOR_WRITES_CONFIG=0 run_handoff
check "the launcher still exits nonzero" "1" "$?"
check "no install was started" "no" "$(installed)"
[[ -e $sandbox/root/user_configuration.json ]]
check "the stale configuration was cleared" "1" "$?"

echo "==> a configurator that produced nothing does not start an install"
new_sandbox
CONFIGURATOR_EXIT=0 CONFIGURATOR_WRITES_CONFIG=0 run_handoff
check "the launcher exits nonzero" "1" "$?"
check "no install was started" "no" "$(installed)"

echo "==> a completed wizard still starts the install"
new_sandbox
CONFIGURATOR_EXIT=0 CONFIGURATOR_WRITES_CONFIG=1 run_handoff
check "the launcher exits clean" "0" "$?"
check "the install was started" "yes" "$(installed)"

echo "==> autoinstall from a cidata drive still starts the install"
new_sandbox
echo '{"disk_config": {}}' >"$sandbox/root/cidata-config"
cat >"$sandbox/bin/omarchy-cidata-load" <<STUB
#!/bin/bash
cp "$sandbox/root/cidata-config" "$sandbox/root/user_configuration.json"
STUB
chmod +x "$sandbox/bin/omarchy-cidata-load"
run_handoff
check "the launcher exits clean" "0" "$?"
check "the install was started" "yes" "$(installed)"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
