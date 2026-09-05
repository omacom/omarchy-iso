#!/bin/bash
#
# omarchy-release-install-target is the one source of truth for letting go of
# the install target, and its exit status is load-bearing: the dashboard's
# removal offer and its immediate `reboot -ff` both key on it, so a sweep that
# quietly gives up must not report success. This drives the script with
# stubbed swapoff/findmnt/umount/dmsetup/cryptsetup on PATH, so every branch —
# the swap hunt, the crypt gate, the failure exits — is checked without a disk.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/usr/local/bin/omarchy-release-install-target"

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

check_absent() { # desc, needle, haystack
  local desc=$1 needle=$2 hay=$3
  if [[ $hay == *"$needle"* ]]; then
    echo "FAIL: $desc (unexpected '$needle' in: $hay)"; fails=1; return
  fi
  echo "ok: $desc"
}

call_order() { # desc, earlier-call-pattern, later-call-pattern
  # First match of each pattern in $CALLS, by line. A missing call is its own
  # failure, not a script abort: the bare grep pipelines here would otherwise
  # kill the whole test under set -euo pipefail exactly when they had
  # something to say.
  local desc=$1 first second
  first=$(grep -n "$2" <<<"$CALLS" | head -1 | cut -d: -f1 || true)
  second=$(grep -n "$3" <<<"$CALLS" | head -1 | cut -d: -f1 || true)
  if [[ -z $first || -z $second ]]; then
    echo "FAIL: $desc (missing call: '$2' -> ${first:-none}, '$3' -> ${second:-none})"
    fails=1; return
  fi
  if (( first >= second )); then
    echo "FAIL: $desc ('$2' at line $first, '$3' at line $second)"; fails=1; return
  fi
  echo "ok: $desc"
}

# A sandbox whose stub tools record every call to $BOX/calls and answer from
# fixture files, so a case is set up by writing those files. The stubs model
# the kernel's view rather than a script's: a successful `cryptsetup close`
# drops the mapper from the table dmsetup then reports on, which is what makes
# the close's success or failure observable the way the script observes it.
BOXES=()
trap '(( ${#BOXES[@]} == 0 )) || rm -rf "${BOXES[@]}"' EXIT

new_box() { # -> sets BOX to a fresh sandbox with default (nothing to do) state
  BOX=$(mktemp -d)
  BOXES+=("$BOX")
  export BOX
  mkdir -p "$BOX/bin"
  : >"$BOX/calls"
  : >"$BOX/swaps"        # /proc/swaps body, header already stripped
  : >"$BOX/sources"      # findmnt -o SOURCE -R <target>
  : >"$BOX/mapper_mounts" # findmnt -o TARGET -S /dev/mapper/<name>
  : >"$BOX/uuids"        # "<mapper> <dm uuid>" per line; absent = no such mapper
  echo 1 >"$BOX/mounted_rc"
  echo 0 >"$BOX/umount_rc"
  echo 0 >"$BOX/close_rc"

  cat >"$BOX/bin/sync" <<'EOF'
#!/bin/bash
echo "sync" >>"$BOX/calls"
EOF
  cat >"$BOX/bin/tail" <<'EOF'
#!/bin/bash
# Only /proc/swaps is faked; anything else goes to the real tail.
if [[ ${*: -1} == /proc/swaps ]]; then cat "$BOX/swaps"; exit 0; fi
exec /usr/bin/tail "$@"
EOF
  cat >"$BOX/bin/swapoff" <<'EOF'
#!/bin/bash
echo "swapoff $*" >>"$BOX/calls"
EOF
  cat >"$BOX/bin/findmnt" <<'EOF'
#!/bin/bash
echo "findmnt $*" >>"$BOX/calls"
case "$*" in
  *"-o SOURCE"*) cat "$BOX/sources" ;;
  *"-o TARGET"*) cat "$BOX/mapper_mounts" ;;
  *)             echo "stub findmnt tree" ;;   # the failure diagnosis
esac
EOF
  cat >"$BOX/bin/mountpoint" <<'EOF'
#!/bin/bash
exit "$(cat "$BOX/mounted_rc")"
EOF
  cat >"$BOX/bin/umount" <<'EOF'
#!/bin/bash
echo "umount $*" >>"$BOX/calls"
exit "$(cat "$BOX/umount_rc")"
EOF
  cat >"$BOX/bin/dmsetup" <<'EOF'
#!/bin/bash
echo "dmsetup $*" >>"$BOX/calls"
# Broken mode: dmsetup cannot answer at all — the message shape a real one
# prints when the control node is unreachable (reproduced non-root), which
# the script must keep apart from a mapper that is provably gone.
if [[ -e $BOX/dmsetup_broken ]] ||
   { [[ -e $BOX/dmsetup_broken_after ]] &&
     (( $(grep -c '^dmsetup' "$BOX/calls") > $(cat "$BOX/dmsetup_broken_after") )); }; then
  echo "/dev/mapper/control: open failed: Permission denied" >&2
  echo "Command failed." >&2
  exit 1
fi
mapper="${*: -1}"
uuid=$(awk -v m="$mapper" '$1 == m { print $2 }' "$BOX/uuids")
[[ -n $uuid ]] || { echo "Device does not exist." >&2; exit 1; }
# `info -c -o uuid` is the gate's query; a bare `info` is the failure
# report. The flag is matched positionally: a glob over $* would also hit a
# mapper name containing '-c'.
if [[ ${2:-} == -c ]]; then echo "$uuid"; else echo "Name: $mapper"; fi
EOF
  cat >"$BOX/bin/cryptsetup" <<'EOF'
#!/bin/bash
echo "cryptsetup $*" >>"$BOX/calls"
rc=$(cat "$BOX/close_rc")
# close_removes: the transient shape — cryptsetup reports a failure while
# the mapping is nevertheless gone from the kernel's table.
if (( rc == 0 )) || [[ -e $BOX/close_removes ]]; then
  awk -v m="${*: -1}" '$1 != m' "$BOX/uuids" >"$BOX/uuids.new"
  mv "$BOX/uuids.new" "$BOX/uuids"
fi
exit "$rc"
EOF
  cat >"$BOX/bin/fuser" <<'EOF'
#!/bin/bash
echo "                     USER        PID ACCESS COMMAND"
EOF
  chmod +x "$BOX"/bin/*
  TARGET="$BOX/mnt"
  mkdir -p "$TARGET"
}

run_release() { # extra mapper args -> sets RC, OUT (stderr), CALLS
  set +e
  OUT=$(PATH="$BOX/bin:$PATH" bash "$SCRIPT" "$TARGET" "$@" 2>&1 >/dev/null)
  RC=$?
  set -e
  CALLS=$(cat "$BOX/calls")
}

# ── An idempotent no-op: nothing mounted, no swap, no mapper ─────────────────
new_box
run_release
check "an untouched target releases silently" 0 "$RC"
check_absent "no unmount is attempted with nothing mounted" "umount" "$CALLS"
check_absent "no mapper is closed with nothing open" "cryptsetup" "$CALLS"

# ── The ordinary release: swap off, tree unmounted, crypt mapper closed ──────
new_box
echo 0 >"$BOX/mounted_rc"
printf '%s file 4194300 0 -2\n/dev/zram0 partition 8388604 0 100\n' "$TARGET/swap/swapfile" >"$BOX/swaps"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
run_release
check "a mounted encrypted target is fully released" 0 "$RC"
check "the target's swapfile is deactivated" 0 0 "swapoff $TARGET/swap/swapfile" "$CALLS"
check_absent "swap outside the target is left alone" "/dev/zram0" "$CALLS"
check "the tree is unmounted" 0 0 "umount -R $TARGET" "$CALLS"
check "the mapper off the mount table is closed" 0 0 "cryptsetup close omarchy_root" "$CALLS"
# Swap is an invisible holder: with it still on, the unmount reports busy.
call_order "swapoff comes before the unmount" '^swapoff' '^umount'

# ── A tree that stays mounted fails the release ──────────────────────────────
new_box
echo 0 >"$BOX/mounted_rc"
echo 1 >"$BOX/umount_rc"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
run_release
check "a failed unmount fails the release" 1 "$RC" "could not unmount $TARGET" "$OUT"
check "the holders are named on the way out" 0 0 "ACCESS COMMAND" "$OUT"
check_absent "a target still mounted is not swept for mappers" "cryptsetup" "$CALLS"

# ── A mapper that stays open fails the release too ───────────────────────────
new_box
echo 0 >"$BOX/mounted_rc"
echo 1 >"$BOX/close_rc"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
run_release
check "a mapper that stays open fails the release" 1 "$RC" "could not close mapper omarchy_root" "$OUT"
check "the unmount still happened" 0 0 "umount -R $TARGET" "$CALLS"

# ── The crypt gate: cryptsetup would happily remove what is not ours ─────────
new_box
echo 0 >"$BOX/mounted_rc"
echo "/dev/mapper/vg0-data[/]" >"$BOX/sources"
echo "vg0-data LVM-9f2cIkjHqf0e" >"$BOX/uuids"
run_release
check "a non-crypt mapper is left alone" 0 "$RC"
check_absent "cryptsetup is never called on an LVM mapping" "cryptsetup" "$CALLS"

new_box
echo 0 >"$BOX/mounted_rc"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"   # no uuids entry: gone already
run_release
check "a mapper that is not there falls out silently" 0 "$RC"
check_absent "no close is attempted on a missing mapper" "cryptsetup" "$CALLS"

# ── A dmsetup that cannot answer must not pass for "already gone" ────────────
new_box
echo 0 >"$BOX/mounted_rc"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
touch "$BOX/dmsetup_broken"
run_release
check "an unanswerable mapper query fails the release" 1 "$RC" \
  "could not query mapper omarchy_root" "$OUT"
check_absent "no close is attempted on an unproven mapper" "cryptsetup" "$CALLS"

# ── A close that errors while the mapper is provably gone is forgiven ────────
# The transient shape round 5 could not reproduce on hardware: cryptsetup
# reports a failure, yet device-mapper's table no longer holds the mapping.
# The post-close probe must read that as closed — failing it would tell a
# healthy machine to leave the medium in and take the graceful reboot.
new_box
echo 0 >"$BOX/mounted_rc"
echo 1 >"$BOX/close_rc"
touch "$BOX/close_removes"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
run_release
check "a failed close with the mapper gone still releases" 0 "$RC"
check_absent "and reports nothing to hold the medium for" "could not close" "$OUT"

# ── dmsetup dying between the close and its probe is still a failed close ────
new_box
echo 0 >"$BOX/mounted_rc"
echo 1 >"$BOX/close_rc"
echo "/dev/mapper/omarchy_root[/@]" >"$BOX/sources"
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
echo 1 >"$BOX/dmsetup_broken_after"   # the gate's query answers; every later call breaks
run_release
check "an unanswerable post-close probe fails the release" 1 "$RC" \
  "could not close mapper omarchy_root" "$OUT"

# ── Mappers named as arguments: the open-but-never-mounted window ────────────
new_box
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
run_release omarchy_root
check "a named mapper is closed with nothing mounted" 0 "$RC" "cryptsetup close omarchy_root" "$CALLS"

# ── A mapper mounted outside the target tree ─────────────────────────────────
new_box
echo "omarchy_root CRYPT-LUKS2-2b0e-omarchy_root" >"$BOX/uuids"
echo "/run/omarchy-install/image-top" >"$BOX/mapper_mounts"
run_release omarchy_root
check "a stage mount outside the target is unmounted" 0 "$RC" \
  "umount -R /run/omarchy-install/image-top" "$CALLS"
call_order "the stage mount goes before the close" '^umount -R /run' '^cryptsetup close'

if (( fails )); then
  echo "omarchy-release-install-target: FAILED"
  exit 1
fi
echo "ok: omarchy-release-install-target sweeps and reports"
