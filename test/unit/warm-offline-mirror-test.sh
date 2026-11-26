#!/bin/bash
#
# omarchy-cache-warm.service warms the page cache off the install medium while
# the user is in the wizard, only after both boot-time verifiers and LUKS
# Argon2id calibration finish. This verifies the systemd unit wiring and runs
# omarchy-cache-warm against a systemctl stub that replays a boot as systemd
# reports it, with a cat stub recording which phase each read landed in.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/configs/airootfs/usr/local/bin/omarchy-cache-warm"
UNIT="$ROOT/configs/airootfs/etc/systemd/system/omarchy-cache-warm.service"
WANTED="$ROOT/configs/airootfs/etc/systemd/system/multi-user.target.wants/omarchy-cache-warm.service"
AUTO="$ROOT/configs/airootfs/root/.automated_script.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x $TOOL ]] || fail "omarchy-cache-warm is missing or not executable"
[[ -f $UNIT ]] || fail "omarchy-cache-warm.service is missing"
[[ -L $WANTED && $(readlink "$WANTED") == ../omarchy-cache-warm.service ]] \
  || fail "omarchy-cache-warm.service is not enabled in multi-user.target.wants"
grep -q '"/usr/local/bin/omarchy-cache-warm"\]="0:0:755"' "$ROOT/configs/profiledef.sh" \
  || fail "omarchy-cache-warm is not marked executable in profiledef.sh"
grep -q '^After=.*omarchy-mirror-verify\.service.*omarchy-root-image-verify\.service.*omarchy-luks-calibrate\.service' "$UNIT" \
  || fail "omarchy-cache-warm.service does not order after verify and calibration units"
grep -q '^Type=exec$' "$UNIT" || fail "omarchy-cache-warm.service must be Type=exec"
grep -q '^ConditionKernelCommandLine=!omarchy\.no_prefetch$' "$UNIT" || fail "omarchy-cache-warm.service missing cmdline opt-out"
grep -q '^Nice=19$' "$UNIT" || fail "omarchy-cache-warm.service missing Nice=19"
grep -q '^IOSchedulingClass=idle$' "$UNIT" || fail "omarchy-cache-warm.service missing IOSchedulingClass=idle"
grep -q '^IOAccounting=yes$' "$UNIT" || fail "omarchy-cache-warm.service missing IOAccounting=yes"
! grep -q 'warm_offline_mirror\|warm_installer_tools\|warm_pid' "$AUTO" \
  || fail ".automated_script.sh still spawns a background warm-up subshell"

mkdir -p "$fixture/bin" "$fixture/medium/arch/$(uname -m)" "$fixture/mirror" "$fixture/orch"
head -c 65536 /dev/zero >"$fixture/medium/arch/$(uname -m)/omarchy-root.sfs"
head -c 65536 /dev/zero >"$fixture/mirror/linux-firmware-1-1-any.pkg.tar.zst"
echo "# orch" >"$fixture/orch/sample.py"
echo "MemAvailable:    8388608 kB" >"$fixture/meminfo"

# Each systemctl call answers for the next phase of the boot (the last one
# repeats), the way systemd reports it in that phase.
cat >"$fixture/bin/systemctl" <<EOF
#!/bin/bash
mapfile -t phases <"$fixture/phases"
phase=\${phases[0]}
((\${#phases[@]} == 1)) || printf '%s\n' "\${phases[@]:1}" >"$fixture/phases"
echo "\$phase" >"$fixture/now"
case "\$1 \$phase" in
  "is-active calibrate")
    [[ \$* == *omarchy-luks-calibrate* ]] && exit 0
    exit 3 ;;
  "is-active "*)
    exit 3 ;;
  "list-jobs mirror")
    echo "1 omarchy-mirror-verify.service     start running"
    echo "2 omarchy-root-image-verify.service start waiting"
    echo "3 omarchy-luks-calibrate.service    start waiting" ;;
  "list-jobs image")
    echo "2 omarchy-root-image-verify.service start running"
    echo "3 omarchy-luks-calibrate.service    start waiting" ;;
  "list-jobs calibrate-queued")
    echo "3 omarchy-luks-calibrate.service    start waiting" ;;
esac
exit 0
EOF
cat >"$fixture/bin/cat" <<EOF
#!/bin/bash
now=before
[[ -f "$fixture/now" ]] && read -r now <"$fixture/now"
for arg in "\$@"; do
  [[ \$arg == -- ]] && continue
  case "\$arg" in
    "$fixture/medium/"* | "$fixture/mirror/"* | "$fixture/orch/"*)
      echo "\$now \${arg##*/}" >>"$fixture/reads" ;;
  esac
done
EOF
printf '#!/bin/sh\n' >"$fixture/bin/sleep"
chmod +x "$fixture"/bin/*

warm_reads() {
  printf '%s\n' "$@" >"$fixture/phases"
  rm -f "$fixture/now" "$fixture/reads"
  (
    PATH="$fixture/bin:$PATH" \
    OMARCHY_BOOTMNT="$fixture/medium" \
    OMARCHY_OFFLINE_MIRROR="$fixture/mirror" \
    OMARCHY_MEMINFO="$fixture/meminfo" \
    OMARCHY_ORCHESTRATOR_DIR="$fixture/orch" \
    bash "$TOOL"
  ) || fail "omarchy-cache-warm failed"
  command cat "$fixture/reads" 2>/dev/null || true
}

# Each calibrate phase calls list-jobs (empty) and then is-active (0 = active).
reads=$(warm_reads mirror mirror image image calibrate-queued calibrate calibrate calibrate calibrate finished finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst\nfinished sample.py' ]] \
  || fail "the warm-up read the medium before verify and LUKS calibration finished: $(paste -sd, <<<"$reads")"

reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst\nfinished sample.py' ]] \
  || fail "the warm-up does not read the medium once the checks are done: $(paste -sd, <<<"$reads")"

# An 8 GiB machine (~7.3 GiB MemAvailable) must still cache a ~3.9 GiB image
# (leaving 2 GiB headroom), while a 4 GiB machine (~3.5 GiB MemAvailable) must
# skip it so it does not evict what verify just cached.
cat >"$fixture/bin/du" <<'EODU'
#!/bin/bash
while [[ ${1:-} == -* ]]; do shift; done
for path in "$@"; do
  case "$path" in
    *omarchy-root.sfs|*omarchy-root.img.zst) printf '3962000\t%s\n' "$path" ;;
    *) printf '64\t%s\n' "$path" ;;
  esac
done
EODU
chmod +x "$fixture/bin/du"

echo "MemAvailable:    7654604 kB" >"$fixture/meminfo"
reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst\nfinished sample.py' ]] \
  || fail "8 GiB machine failed to warm a 3.8 GiB root image: $(paste -sd, <<<"$reads")"

echo "MemAvailable:    3670016 kB" >"$fixture/meminfo"
reads=$(warm_reads finished)
[[ $reads == "finished sample.py" ]] \
  || fail "4 GiB machine warmed an image larger than its budget: $(paste -sd, <<<"$reads")"

# Prefer omarchy-root.img.zst when present alongside hardware layers.
echo "MemAvailable:    8388608 kB" >"$fixture/meminfo"
head -c 65536 /dev/zero >"$fixture/medium/arch/$(uname -m)/omarchy-root.img.zst"
head -c 65536 /dev/zero >"$fixture/medium/arch/$(uname -m)/omarchy-layer.intel-ptl-ipu7.tar.zst"
reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.img.zst\nfinished omarchy-layer.intel-ptl-ipu7.tar.zst\nfinished linux-firmware-1-1-any.pkg.tar.zst\nfinished sample.py' ]] \
  || fail "zstd root image and hardware layer were not warmed in order: $(paste -sd, <<<"$reads")"

# OMARCHY_NO_PREFETCH=1 skips everything.
reads=$(OMARCHY_NO_PREFETCH=1 warm_reads finished)
[[ -z $reads ]] || fail "OMARCHY_NO_PREFETCH=1 did not disable warm-up"

echo "warm offline mirror tests passed"
