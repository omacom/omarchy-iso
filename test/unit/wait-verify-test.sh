#!/bin/bash
#
# omarchy-wait-verify is the single gate both disk-touching paths
# clear before formatting: the orchestrator (full-disk) and the configurator
# (free-space). It collects the boot-time hasher's verdict, waiting if it is
# still running and starting it if it never did. This drives it with a stubbed
# systemctl/findmnt/lsblk/journalctl and a fake boot medium on PATH, so the
# wait/verdict logic is checked without an ISO.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HELPER="$ROOT/configs/airootfs/usr/local/bin/omarchy-wait-verify"

fails=0
check() { # desc, expected_rc, actual_rc, [needle in output], [output]
  local desc=$1 want=$2 got=$3 needle=${4:-} out=${5:-}
  if [[ $got != "$want" ]]; then
    echo "FAIL: $desc (rc want=$want got=$got)"; fails=1; return
  fi
  if [[ -n $needle && $out != *"$needle"* ]]; then
    echo "FAIL: $desc (missing '$needle' in: $out)"; fails=1; return
  fi
  echo "ok: $desc"
}

# A sandbox with a fake boot medium and stub tools on PATH. ACTIVE_SEQ is the
# newline-separated ActiveState values `systemctl show ... ActiveState` returns
# on successive calls (last one repeats); LOADSTATE, START_RC and RESULT (the
# unit's Result property, exit-code unless overridden) tune the rest.
run_helper() { # loadstate, active_seq, start_rc, [result], [exec_status]  ->  sets RC and OUT
  local loadstate=$1 active_seq=$2 start_rc=$3 result=${4:-exit-code} exec_status=${5:-1}
  local box; box=$(mktemp -d)
  mkdir -p "$box/bin" "$box/medium/arch/x86_64" "$box/sys/block/sdz/queue"
  : >"$box/medium/arch/x86_64/omarchy-root.btrfs.zst"
  : >"$box/medium/arch/x86_64/omarchy-root.btrfs.zst.sha256"

  # WITH_HASHER_PROC=1: a fake hasher (pid 4242) holds the stream at pos 512
  # of 1024 bytes, and the helper draws progress into $box/progress. The shim
  # rewrites /proc to the sandbox, so hash_pct reads this fixture.
  local mainpid=0
  if [[ -n ${WITH_HASHER_PROC:-} ]]; then
    mainpid=4242
    head -c 1024 /dev/zero >"$box/medium/arch/x86_64/omarchy-root.btrfs.zst"
    mkdir -p "$box/proc/4242/fd" "$box/proc/4242/fdinfo"
    ln -s "$box/medium/arch/x86_64/omarchy-root.btrfs.zst" "$box/proc/4242/fd/7"
    printf 'pos:\t512\nflags:\t0100000\n' >"$box/proc/4242/fdinfo/7"
  fi
  echo "none mq-deadline kyber [bfq]" >"$box/sys/block/sdz/queue/scheduler"
  printf '%s\n' "$active_seq" >"$box/active_seq"

  cat >"$box/bin/findmnt" <<EOF
#!/bin/bash
echo /dev/sdz1
EOF
  cat >"$box/bin/lsblk" <<EOF
#!/bin/bash
echo sdz
EOF
  cat >"$box/bin/journalctl" <<'EOF'
#!/bin/bash
echo "omarchy-root.btrfs.zst: FAILED"
EOF
  # systemctl show -p LoadState|ActiveState --value ; systemctl start ...
  cat >"$box/bin/systemctl" <<EOF
#!/bin/bash
box="$box"; start_rc=$start_rc; loadstate="$loadstate"; result="$result"; mainpid=$mainpid; exec_status=$exec_status
if [[ \$1 == show ]]; then
  case "\$*" in
    *LoadState*)  echo "\$loadstate" ;;
    *ExecMainStatus*) echo "\$exec_status" ;;
    *Result*)     echo "\$result" ;;
    *MainPID*)    echo "\$mainpid" ;;
    *ActiveState*)
      # pop the first remaining line; keep the last forever
      mapfile -t seq <"\$box/active_seq"
      echo "\${seq[0]}"
      if ((\${#seq[@]} > 1)); then printf '%s\n' "\${seq[@]:1}" >"\$box/active_seq"; fi
      ;;
  esac
  exit 0
fi
if [[ \$1 == start ]]; then exit \$start_rc; fi
exit 0
EOF
  chmod +x "$box"/bin/*

  # Point the helper's hardcoded /run/archiso/bootmnt and /sys at the sandbox
  # by running it through a tiny shim that rewrites those roots.
  local shim="$box/run-helper"
  sed -e "s#/run/archiso/bootmnt#$box/medium#g" \
      -e "s#/sys/block#$box/sys/block#g" \
      -e "s#/proc/#$box/proc/#g" \
      "$HELPER" >"$shim"
  chmod +x "$shim"

  local progress_env=()
  [[ -n ${WITH_HASHER_PROC:-} ]] && progress_env=(OMARCHY_VERIFY_PROGRESS="$box/progress")

  set +e
  # The helper takes its unit, its subject and (for the progress percentage)
  # the stream, so the sandbox passes what the orchestrator passes.
  OUT=$(PATH="$box/bin:$PATH" env "${progress_env[@]}" bash "$shim" \
    omarchy-root-image-verify.service "the root image" \
    "$box/medium/arch/x86_64/omarchy-root.btrfs.zst" 2>&1)
  RC=$?
  set -e
  PROGRESS_OUT=$(cat "$box/progress" 2>/dev/null || true)
  rm -rf "$box"
}

# Already verified before we look: pass, and the scheduler line is emitted.
run_helper loaded "active" 0
check "active unit passes" 0 "$RC" "scheduler: none mq-deadline kyber [bfq]" "$OUT"

# Still hashing, then completes: waits, then passes.
run_helper loaded $'activating\nactivating\nactive' 0
check "waits for a running unit then passes" 0 "$RC" "waiting for" "$OUT"

# With OMARCHY_VERIFY_PROGRESS set and a hasher pid to read, the wait draws a
# live percent (fixture: pos 512 of 1024 -> 50%) and finishes the line at 100%
# on success. Progress goes to the given path, never into stdout/stderr.
WITH_HASHER_PROC=1 run_helper loaded $'activating\nactivating\nactive' 0
check "progress line drawn while hashing" 0 "$RC" "" "$OUT"
[[ $PROGRESS_OUT == *" 50%"* && $PROGRESS_OUT == *"100%"* ]] &&
  echo "ok: progress shows 50% then 100%" ||
  { echo "FAIL: progress output wrong: $(printf '%q' "$PROGRESS_OUT")"; fails=1; }
[[ $OUT == *"50%"* ]] && { echo "FAIL: percent leaked into stdout/stderr"; fails=1; } || true

# A failed hash ends the progress line without the cosmetic 100%. (The first
# ActiveState answer is consumed by the inactive check before the wait loop.)
WITH_HASHER_PROC=1 run_helper loaded $'activating\nactivating\nfailed' 0
[[ $PROGRESS_OUT == *" 50%"* && $PROGRESS_OUT != *"100%"* ]] &&
  echo "ok: failed hash ends progress without 100%" ||
  { echo "FAIL: failed-hash progress wrong: $(printf '%q' "$PROGRESS_OUT")"; fails=1; }

# Hash failed: corrupt medium, re-flash message leads.
run_helper loaded "failed" 0
check "failed unit is a corrupt medium" 1 "$RC" "install medium is corrupt: re-flash it" "$OUT"

# Hash hit the size-based TimeoutStartSec: the medium stalls reads. Distinct
# advice -- re-flashing the same stick would not help.
run_helper loaded "failed" 0 timeout
check "timed-out unit is a slow medium" 1 "$RC" "install medium is too slow" "$OUT"

# The stall watchdog killed a hash whose reads stopped advancing (exit 75):
# the same slow-medium advice, reached in seconds instead of minutes, and
# named as a stall rather than a size timeout or a corrupt image.
run_helper loaded "failed" 0 exit-code 75
check "a stall-killed unit is a slow medium" 1 "$RC" "install medium is too slow" "$OUT"
check "a stall names itself" 1 "$RC" "stalled: the medium stopped returning data" "$OUT"

# systemd stops a timed-out unit before it settles into failed, so the wait
# passes through deactivating. Waiting that out is what keeps the slow-medium
# advice: classifying it as terminal answered "did not run" instead.
run_helper loaded $'activating\ndeactivating\ndeactivating\nfailed' 0 timeout
check "a unit still stopping is waited out, not called unrunnable" 1 "$RC" \
  "install medium is too slow" "$OUT"

# Never started and start leaves it inactive: cannot verify.
run_helper loaded "inactive" 0
check "unit that will not run fails" 1 "$RC" "did not run" "$OUT"

# Unit not on this system.
run_helper not-found "inactive" 0
check "missing unit fails" 1 "$RC" "not on this live system" "$OUT"

[[ $fails -eq 0 ]] && echo "ok: omarchy-wait-verify gate behaves"
exit "$fails"
