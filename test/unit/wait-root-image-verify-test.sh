#!/bin/bash
#
# omarchy-wait-root-image-verify is the single gate both disk-touching paths
# clear before formatting: the orchestrator (full-disk) and the configurator
# (free-space). It collects the boot-time hasher's verdict, waiting if it is
# still running and starting it if it never did. This drives it with a stubbed
# systemctl/findmnt/lsblk/journalctl and a fake boot medium on PATH, so the
# wait/verdict logic is checked without an ISO.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HELPER="$ROOT/configs/airootfs/usr/local/bin/omarchy-wait-root-image-verify"

# Absolute path, resolved before any sandbox shadows $PATH: the harness's own
# 120 s guard must stay the real timeout even when a test scripts expiry for
# the helper's cold reads.
REAL_TIMEOUT=$(command -v timeout 2>/dev/null || echo timeout)

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
# MIRROR_SEQ, when set, ships the mirror's sums file and gives
# omarchy-mirror-verify.service its own ActiveState sequence (MIRROR_RESULT its
# Result); without it the sandbox is an ISO without the mirror's sums file.
run_helper() { # loadstate, active_seq, start_rc, [result]  ->  sets RC and OUT
  local loadstate=$1 active_seq=$2 start_rc=$3 result=${4:-exit-code}
  local box; box=$(mktemp -d)
  mkdir -p "$box/bin" "$box/medium/arch/x86_64" "$box/sys/block/sdz/queue"
  : >"$box/medium/arch/x86_64/omarchy-root.img.zst"
  : >"$box/medium/arch/x86_64/omarchy-root.img.zst.sha256"
  # SUMS_EXPECTED: the checksum the sandbox image is "built" with.
  [[ -n ${SUMS_EXPECTED:-} ]] && printf '%s  %s\n' "$SUMS_EXPECTED" omarchy-root.img.zst >"$box/medium/arch/x86_64/omarchy-root.img.zst.sha256"
  # DROPCACHES=1: the live /proc/sys/vm/drop_caches exists, so the helper's
  # cold re-reads run. Without it every cold path reports unknown, which is
  # how the pre-existing tests below keep exercising the unit's own verdict.
  if [[ -n ${DROPCACHES:-} ]]; then
    mkdir -p "$box/proc/sys/vm"
    : >"$box/proc/sys/vm/drop_caches"
  fi
  # SUMS_STUB=1: scripted sha256sum. SUMS_OUT1/SUMS_OUT2 are the literal
  # stdout of the first/second call (multi-line ok), SUMS_RC1/SUMS_RC2 their
  # exit codes (default 0). Absent SUMS_STUB the real sha256sum runs. Every
  # call logs its argv for assertions about which files get hashed how.
  if [[ -n ${SUMS_STUB:-} ]]; then
    echo 1 >"$box/sums_n"
    : >"$box/sha256_argv"
    [[ -n ${SUMS_OUT1:-} ]] && printf '%s\n' "$SUMS_OUT1" >"$box/sums_out1"
    [[ -n ${SUMS_OUT2:-} ]] && printf '%s\n' "$SUMS_OUT2" >"$box/sums_out2"
    printf '%s\n' "${SUMS_RC1:-0}" >"$box/sums_rc1"
    printf '%s\n' "${SUMS_RC2:-0}" >"$box/sums_rc2"
    cat >"$box/bin/sha256sum" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$box/sha256_argv"
n=\$(cat "$box/sums_n")
printf '%s' "\$(cat "$box/sums_out\$n" 2>/dev/null)"
rc=\$(cat "$box/sums_rc\$n" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$box/sums_n"
exit "\$rc"
EOF
  fi
  # TIMEOUT_STUB=1: scripted timeout. Passes the duration and command through
  # (shift; exec), so cold reads behave normally. With TIMEOUT_EXPIRE=1 it
  # exits 124 without running anything, like a stalled read hitting the cap.
  if [[ -n ${TIMEOUT_STUB:-} ]]; then
    cat >"$box/bin/timeout" <<EOF
#!/bin/bash
if [[ -n "\${TIMEOUT_EXPIRE:-}" ]]; then exit 124; fi
shift
exec "\$@"
EOF
  fi

  # WITH_HASHER_PROC=1: a fake hasher (pid 4242) holds the image at pos 512
  # of 1024 bytes, and the helper draws progress into $box/progress. The shim
  # rewrites /proc to the sandbox, so hash_pct reads this fixture.
  local mainpid=0
  if [[ -n ${WITH_HASHER_PROC:-} ]]; then
    mainpid=4242
    head -c 1024 /dev/zero >"$box/medium/arch/x86_64/omarchy-root.img.zst"
    mkdir -p "$box/proc/4242/fd" "$box/proc/4242/fdinfo"
    ln -s "$box/medium/arch/x86_64/omarchy-root.img.zst" "$box/proc/4242/fd/7"
    printf 'pos:\t512\nflags:\t0100000\n' >"$box/proc/4242/fdinfo/7"
  fi
  echo "none mq-deadline kyber [bfq]" >"$box/sys/block/sdz/queue/scheduler"
  printf '%s\n' "$active_seq" >"$box/active_seq"
  printf '%s\n' "$loadstate" >"$box/load_seq"
  printf '%s\n' "${MIRROR_SEQ:-inactive}" >"$box/mirror_seq"
  [[ -n ${MIRROR_SEQ:-} ]] && printf '%s\n' "0000  a.pkg.tar.zst" "0000  b.pkg.tar.zst" \
    "0000  linux-t2.pkg.tar.zst" "0000  offline.db.tar.gz" >"$box/sums"
  # WITH_MIRROR_HASHER=1: the mirror hasher (pid 4343) has the third of the
  # four files open, so the packages line reads 50%.
  local mirror_pid=0
  if [[ -n ${WITH_MIRROR_HASHER:-} ]]; then
    mirror_pid=4343
    mkdir -p "$box/mirror" "$box/proc/4343/fd" "$box/proc/4343/fdinfo"
    : >"$box/mirror/linux-t2.pkg.tar.zst"
    ln -s "$box/mirror/linux-t2.pkg.tar.zst" "$box/proc/4343/fd/5"
    printf 'pos:\t100\nflags:\t0100000\n' >"$box/proc/4343/fdinfo/5"
  fi

  cat >"$box/bin/findmnt" <<EOF
#!/bin/bash
echo /dev/sdz1
EOF
  cat >"$box/bin/lsblk" <<EOF
#!/bin/bash
echo sdz
EOF
  # sha256sum's summary line reaches the journal JOURNAL_LATE reads late (0:
  # on the first read), as it can on a real system right after the unit fails.
  printf '%s\n' "${JOURNAL_LATE:-0}" >"$box/journal_late"
  cat >"$box/bin/journalctl" <<EOF
#!/bin/bash
[[ \$1 == --sync ]] && exit 0
late=\$(cat "$box/journal_late")
if [[ \$* == *omarchy-mirror-verify* ]]; then
  echo "linux-t2.pkg.tar.zst: FAILED"
  echo "sha256sum: WARNING: 1 computed checksum did NOT match"
  exit 0
fi
echo "omarchy-root.img.zst: FAILED"
if ((late > 0)); then echo \$((late - 1)) >"$box/journal_late"; exit 0; fi
echo "sha256sum: WARNING: 1 computed checksum did NOT match"
EOF
  # systemctl show -p LoadState|ActiveState --value ; systemctl start ...
  cat >"$box/bin/systemctl" <<EOF
#!/bin/bash
box="$box"; start_rc=$start_rc; loadstate="$loadstate"; result="$result"; mainpid=$mainpid
if [[ \$1 == show && \$* == *omarchy-mirror-verify* ]]; then
  case "\$*" in
    *LoadState*)  echo loaded ;;
    *Result*)     echo "${MIRROR_RESULT:-exit-code}" ;;
    *MainPID*)    echo $mirror_pid ;;
    *ActiveState*)
      mapfile -t seq <"\$box/mirror_seq"
      echo "\${seq[0]}"
      if ((\${#seq[@]} > 1)); then printf '%s\n' "\${seq[@]:1}" >"\$box/mirror_seq"; fi
      ;;
  esac
  exit 0
fi
if [[ \$1 == show ]]; then
  case "\$*" in
    *LoadState*)
      mapfile -t seq <"\$box/load_seq"
      echo "\${seq[0]}"
      if ((\${#seq[@]} > 1)); then printf '%s\n' "\${seq[@]:1}" >"\$box/load_seq"; fi
      ;;
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
# START_SLEEP: seconds systemctl start takes to return, as a real start
# waits for the oneshot it starts to exit.
if [[ \$1 == start ]]; then sleep ${START_SLEEP:-0}; exit \$start_rc; fi
exit 0
EOF
  chmod +x "$box"/bin/*

  # Point the helper's hardcoded /run/archiso/bootmnt and /sys at the sandbox
  # by running it through a tiny shim that rewrites those roots.
  local shim="$box/run-helper"
  sed -e "s#/run/archiso/bootmnt#$box/medium#g" \
      -e "s#/sys/block#$box/sys/block#g" \
      -e "s#/proc/#$box/proc/#g" \
      -e "s#/usr/share/omarchy-iso/offline-mirror.sha256#$box/sums#g" \
      -e "s#/var/cache/omarchy/mirror/offline#$box/mirror#g" \
      "$HELPER" >"$shim"
  chmod +x "$shim"

  local progress_env=()
  [[ -n ${WITH_HASHER_PROC:-}${WITH_MIRROR_HASHER:-} ]] && progress_env=(OMARCHY_VERIFY_PROGRESS="$box/progress")
  [[ -n ${INDENT:-} ]] && progress_env+=(OMARCHY_VERIFY_PROGRESS_INDENT="$INDENT")

  set +e
  OUT=$(PATH="$box/bin:$PATH" OMARCHY_VERIFY_RETRY_SECONDS=0 OMARCHY_VERIFY_STALL_SECONDS="${STALL:-60}" \
    env "${progress_env[@]}" "$REAL_TIMEOUT" 120 bash "$shim" 2>&1)
  RC=$?
  set -e
  PROGRESS_OUT=$(cat "$box/progress" 2>/dev/null || true)
  ARGV_OUT=$(cat "$box/sha256_argv" 2>/dev/null || true)
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

# The configurator passes its left padding, so the line starts under its own
# text instead of at column 0.
INDENT=4 WITH_HASHER_PROC=1 run_helper loaded $'activating\nactivating\nactive' 0
[[ $PROGRESS_OUT == $'\r    verifying the install medium:  50%'* && $PROGRESS_OUT == *$'\r    verifying the install medium: 100%'* ]] &&
  echo "ok: progress is indented by OMARCHY_VERIFY_PROGRESS_INDENT" ||
  { echo "FAIL: indented progress wrong: $(printf '%q' "$PROGRESS_OUT")"; fails=1; }

# A failed hash ends the progress line without the cosmetic 100%. (The first
# ActiveState answer is consumed by the inactive check before the wait loop.)
WITH_HASHER_PROC=1 run_helper loaded $'activating\nactivating\nfailed' 0
[[ $PROGRESS_OUT == *" 50%"* && $PROGRESS_OUT != *"100%"* ]] &&
  echo "ok: failed hash ends progress without 100%" ||
  { echo "FAIL: failed-hash progress wrong: $(printf '%q' "$PROGRESS_OUT")"; fails=1; }

# Hash failed: corrupt medium, re-flash message leads.
run_helper loaded "failed" 0
check "failed unit is a corrupt medium" 1 "$RC" "install medium is corrupt: re-flash it" "$OUT"

# The failed hash's verdict is in the message even when sha256sum's summary
# line reaches the journal after the unit is already reported failed (seen
# in CI under low memory: the message lacked "did NOT match" while the
# journal collected afterwards had it).
JOURNAL_LATE=2 run_helper loaded "failed" 0
check "a late journal still gets the verdict into the message" 1 "$RC" "did NOT match" "$OUT"

# systemctl answering nothing at first is systemd not answering yet (on a dying
# medium systemctl itself is paged in slowly), not a missing unit: ask again.
# Seen in CI: "is not on this live system" on a choked
# medium whose unit then timed out.
run_helper $'\n\nloaded' "failed" 0 timeout
check "empty LoadState answers are retried, not a missing unit" 1 "$RC" "install medium is too slow" "$OUT"
[[ $OUT != *"not on this live system"* ]] && echo "ok: no missing-unit claim after empty answers" ||
  { echo "FAIL: empty answers reported as a missing unit: $OUT"; fails=1; }

# If systemd never answers, say that, not that the unit is missing.
run_helper "" "failed" 0
check "no answer at all is reported as systemd not answering" 1 "$RC" "systemd is not answering" "$OUT"

# Hash hit the size-based TimeoutStartSec: the medium stalls reads. Distinct
# advice -- re-flashing the same stick would not help.
run_helper loaded "failed" 0 timeout
check "timed-out unit is a slow medium" 1 "$RC" "install medium is too slow" "$OUT"

# systemd stops a timed-out unit before it settles into failed, so the wait
# passes through deactivating. Waiting that out is what keeps the slow-medium
# advice: classifying it as terminal answered "did not run" instead.
run_helper loaded $'activating\ndeactivating\ndeactivating\nfailed' 0 timeout
check "a unit still stopping is waited out, not called unrunnable" 1 "$RC" \
  "install medium is too slow" "$OUT"

# A unit the helper has to start itself is watched for a stall too: systemctl
# start waits for the oneshot to exit, so blocking on it would wait out the
# size-based timeout instead (here a start that takes 30 s).
began=$SECONDS
STALL=1 WITH_HASHER_PROC=1 START_SLEEP=30 run_helper loaded $'inactive\nactivating' 0
check "a stall in a unit the helper started is reported" 1 "$RC" "install medium stopped responding" "$OUT"
((SECONDS - began < 15)) && echo "ok: the stall is reported without waiting for systemctl start" ||
  { echo "FAIL: the stall took $((SECONDS - began)) s to report: the wait sat in systemctl start"; fails=1; }

# Inactive while that start is still waiting is its job queued, not a unit
# that will not run.
START_SLEEP=2 run_helper loaded $'inactive\ninactive\nactive' 0
check "a queued start is waited for" 0 "$RC" "" "$OUT"

# Never started and start leaves it inactive: cannot verify.
run_helper loaded "inactive" 0
check "unit that will not run fails" 1 "$RC" "did not run" "$OUT"

# Unit not on this system.
run_helper not-found "inactive" 0
check "missing unit fails" 1 "$RC" "not on this live system" "$OUT"

# --- the package mirror -----------------------------------------------------

# Both verified: pass.
MIRROR_SEQ=active run_helper loaded "active" 0
check "image and mirror verified passes" 0 "$RC" "" "$OUT"

# The mirror is still hashing when the image is done: wait for it too.
MIRROR_SEQ=$'activating\nactivating\nactive' run_helper loaded "active" 0
check "waits for the mirror hash" 0 "$RC" \
  "waiting for omarchy-mirror-verify.service to finish hashing the package mirror" "$OUT"

# A corrupt package fails the gate before any disk is touched, and says which.
MIRROR_SEQ=failed run_helper loaded "active" 0
check "a corrupt mirror package is a corrupt medium" 1 "$RC" "sha256 mismatch on the package mirror" "$OUT"
[[ $OUT == *"linux-t2.pkg.tar.zst: FAILED"* ]] && echo "ok: the failing package is named" ||
  { echo "FAIL: the failing package is not named: $OUT"; fails=1; }

# The mirror's own size-based timeout is a slow medium, like the image's.
MIRROR_SEQ=failed MIRROR_RESULT=timeout run_helper loaded "active" 0
check "a timed-out mirror hash is a slow medium" 1 "$RC" \
  "reading the package mirror did not finish within its size-based timeout" "$OUT"

# A mirror unit that will not run fails the gate: the sums are there to be checked.
MIRROR_SEQ=inactive run_helper loaded "active" 0
check "a mirror unit that will not run fails" 1 "$RC" "cannot verify the package mirror" "$OUT"

# The free-space gate's progress line names the packages stage on its own.
WITH_MIRROR_HASHER=1 MIRROR_SEQ=$'activating\nactivating\nactive' run_helper loaded "active" 0
check "mirror hash with a progress line passes" 0 "$RC" "" "$OUT"
[[ $PROGRESS_OUT == *"packages:  50%"* && $PROGRESS_OUT == *"packages: 100%"* ]] &&
  echo "ok: the packages progress shows 50% then 100%" ||
  { echo "FAIL: packages progress wrong: $(printf '%q' "$PROGRESS_OUT")"; fails=1; }

# A hasher whose offset stops moving while the install waits on it is a medium
# that stopped answering: say so, rather than wait out the size-based timeout.
# (The fixture's hasher sits at byte 512 for good.)
STALL=1 WITH_HASHER_PROC=1 run_helper loaded "activating" 0
check "a stalled hash is reported" 1 "$RC" "install medium stopped responding" "$OUT"

# The mirror's verdict comes first: a corrupt package fails the gate before
# the image's verdict is waited for (the image unit here never finishes).
MIRROR_SEQ=failed run_helper loaded "activating" 0
check "a corrupt mirror fails before the image is waited for" 1 "$RC" "sha256 mismatch on the package mirror" "$OUT"

# Mirror verified, image corrupt: the image's verdict.
MIRROR_SEQ=active run_helper loaded "failed" 0
check "a verified mirror and a corrupt image is a corrupt image" 1 "$RC" "sha256 mismatch on the root image" "$OUT"

# --- cold re-reads after a failed hash --------------------------------------
# With drop_caches available and scripted sha256sum output, a cold read that
# matches clears the gate: the unit hashed poisoned cache.
SUMS_EXPECTED=40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d \
SUMS_STUB=1 TIMEOUT_STUB=1 DROPCACHES=1 \
SUMS_OUT1="40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d  omarchy-root.img.zst" \
  run_helper loaded "failed" 0
check "a cold read that matches clears the gate" 0 "$RC" "" "$OUT"

# Two cold reads that disagree with each other are unstable reads, not a
# corrupt medium -- and never the re-flash advice.
SUMS_EXPECTED=40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d \
SUMS_STUB=1 TIMEOUT_STUB=1 DROPCACHES=1 \
SUMS_OUT1="ba79a0d0f5aadeb30be9f8490f596073c92df6e653d8c2a9a04ee8cf3cf0eb4c  omarchy-root.img.zst" \
SUMS_OUT2="59e22734cd9a0bb52bf6c37ba18e7d5e0734418f5ef967efc721df9ba9d8f886  omarchy-root.img.zst" \
  run_helper loaded "failed" 0
check "two differing cold reads report unstable reads" 1 "$RC" "install medium reads are unstable" "$OUT"
[[ $OUT == *"suspect USB stick/port, controller, or RAM"* ]] && echo "ok: unstable reads name USB first" || \
  { echo "FAIL: unstable reads headline wrong: $OUT"; fails=1; }

# Two cold reads that agree, but not with the expected sums, stay corrupt --
# and the message carries both hashes plus the size for forensics.
SUMS_EXPECTED=40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d \
SUMS_STUB=1 TIMEOUT_STUB=1 DROPCACHES=1 \
SUMS_OUT1="7c0664f49b6e88a87906a896ac75f534ddd30d2412247a00985d552335a1501a  omarchy-root.img.zst" \
SUMS_OUT2="7c0664f49b6e88a87906a896ac75f534ddd30d2412247a00985d552335a1501a  omarchy-root.img.zst" \
  run_helper loaded "failed" 0
check "two agreeing wrong cold reads stay corrupt" 1 "$RC" "install medium is corrupt: re-flash it" "$OUT"
[[ $OUT == *"expected 40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d"* ]] && echo "ok: forensics carry the expected hash" || \
  { echo "FAIL: expected hash missing from message: $OUT"; fails=1; }
[[ $OUT == *"computed 7c0664f49b6e88a87906a896ac75f534ddd30d2412247a00985d552335a1501a"* ]] && echo "ok: forensics carry the computed hash" || \
  { echo "FAIL: computed hash missing from message: $OUT"; fails=1; }
[[ $OUT == *"size 0 bytes"* ]] && echo "ok: forensics carry the size" || \
  { echo "FAIL: size missing from message: $OUT"; fails=1; }

# Without drop_caches there is nothing to re-read cold with: the unit's own
# verdict stands, with no forensics grafted on.
SUMS_EXPECTED=40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d \
SUMS_STUB=1 \
SUMS_OUT1="40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d  omarchy-root.img.zst" \
  run_helper loaded "failed" 0
check "no drop_caches falls back to the unit's verdict" 1 "$RC" "install medium is corrupt: re-flash it" "$OUT"
[[ $OUT != *"expected 40dd"* ]] && echo "ok: no forensics without a cold read" || \
  { echo "FAIL: forensics without a cold read: $OUT"; fails=1; }

# Mirror cold path: a failing package list followed by a clean one clears the
# gate the same way a matching image read does. The cold check must address
# the sums file by its absolute path (bare basenames resolve against the
# mirror dir, exactly like the unit): assert that from the logged argv.
MIRROR_SEQ=failed WITH_MIRROR_HASHER=1 SUMS_STUB=1 TIMEOUT_STUB=1 DROPCACHES=1 \
SUMS_OUT1="linux-t2.pkg.tar.zst: FAILED" SUMS_RC1=1 SUMS_OUT2="" SUMS_RC2=0 \
  run_helper loaded "active" 0
check "a mirror cold read that matches clears the gate" 0 "$RC" "" "$OUT"
[[ $ARGV_OUT == *"/sums"* ]] && echo "ok: cold mirror read uses the absolute sums path" || \
  { echo "FAIL: cold mirror read did not use the absolute sums path: $ARGV_OUT"; fails=1; }

# Mirror cold reads that keep failing name the mirror, persistently.
MIRROR_SEQ=failed WITH_MIRROR_HASHER=1 SUMS_STUB=1 TIMEOUT_STUB=1 DROPCACHES=1 \
SUMS_OUT1="linux-t2.pkg.tar.zst: FAILED" SUMS_RC1=1 \
SUMS_OUT2="linux-t2.pkg.tar.zst: FAILED" SUMS_RC2=1 \
  run_helper loaded "active" 0
check "mirror cold reads that keep failing stay corrupt" 1 "$RC" "sha256 mismatch on the package mirror" "$OUT"
[[ $OUT == *"linux-t2.pkg.tar.zst"* ]] && echo "ok: the failing package is named" || \
  { echo "FAIL: failing package missing from message: $OUT"; fails=1; }

# A cold read that stalls past its size-based timeout reports a slow medium,
# not a corrupt one -- and never hangs the installer waiting on dead media.
SUMS_EXPECTED=40dd61f3d9a7e5d8cf86736a8e5a577e5217db65865ad7f895c025876b2f3f8d \
TIMEOUT_STUB=1 TIMEOUT_EXPIRE=1 DROPCACHES=1 \
  run_helper loaded "failed" 0
check "a stalled cold read reports a slow medium" 1 "$RC" "install medium is too slow" "$OUT"
[[ $OUT == *"timed out after 600s"* ]] && echo "ok: the timeout is the size-based one" || \
  { echo "FAIL: size-based timeout missing from message: $OUT"; fails=1; }

[[ $fails -eq 0 ]] && echo "ok: omarchy-wait-root-image-verify gate behaves"
exit "$fails"
