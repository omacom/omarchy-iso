#!/bin/bash
#
# .automated_script.sh warms the page cache off the install medium while the
# user is in the wizard, but only once both boot-time checks of that medium
# are done: two readers on one USB stick seek against each other. This runs
# its warm_offline_mirror against a systemctl stub that replays a boot as
# systemd reports it, and a cat stub that records which part of the boot each
# read of the medium landed in.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/root/.automated_script.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

warm=$(sed -n '/^warm_offline_mirror() {$/,/^}$/p' "$SCRIPT")
[[ -n $warm ]] || fail "warm_offline_mirror is gone from .automated_script.sh"
warm=${warm//\/run\/archiso\/bootmnt/$fixture/medium}
warm=${warm//\/var\/cache\/omarchy\/mirror\/offline/$fixture/mirror}
warm=${warm//\/proc\/meminfo/$fixture/meminfo}

mkdir -p "$fixture/bin" "$fixture/medium/arch/$(uname -m)" "$fixture/mirror"
head -c 65536 /dev/zero >"$fixture/medium/arch/$(uname -m)/omarchy-root.sfs"
head -c 65536 /dev/zero >"$fixture/mirror/linux-firmware-1-1-any.pkg.tar.zst"
echo "MemAvailable:    8388608 kB" >"$fixture/meminfo"

# Each systemctl call answers for the next phase of the boot (the last one
# repeats), the way systemd reports it in that phase:
#   mirror           omarchy-mirror-verify.service hashing; image & calibrate queued
#   image            the mirror check finished, the image hashing; calibrate queued
#   calibrate-queued verify finished, omarchy-luks-calibrate start job still queued
#   calibrate        omarchy-luks-calibrate.service running (Type=exec: no job, active)
#   finished         verify and LUKS calibration finished
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
file=\${!#}
echo "\$now \${file##*/}" >>"$fixture/reads"
EOF
printf '#!/bin/sh\n' >"$fixture/bin/sleep"
chmod +x "$fixture"/bin/*

warm_reads() { # the boot's phases, one per systemctl call -> the reads, one per line
  printf '%s\n' "$@" >"$fixture/phases"
  rm -f "$fixture/now" "$fixture/reads"
  (PATH="$fixture/bin:$PATH"; eval "$warm"; warm_offline_mirror) || fail "warm_offline_mirror failed"
  command cat "$fixture/reads" 2>/dev/null || true
}

# Each calibrate phase calls list-jobs (empty) and then is-active (0 = active).
reads=$(warm_reads mirror mirror image image calibrate-queued calibrate calibrate calibrate calibrate finished finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst' ]] \
  || fail "the warm-up read the medium before verify and LUKS calibration finished: $(paste -sd, <<<"$reads")"

reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst' ]] \
  || fail "the warm-up does not read the medium once the checks are done: $(paste -sd, <<<"$reads")"

# An 8 GiB machine (~7.3 GiB MemAvailable) must still cache a ~3.9 GiB image
# (leaving 2 GiB headroom), while a 4 GiB machine (~3.5 GiB MemAvailable) must
# skip it so it does not evict what verify just cached.
cat >"$fixture/bin/du" <<'EOF'
#!/bin/bash
while [[ ${1:-} == -* ]]; do shift; done
for path in "$@"; do
  case "$path" in
    *omarchy-root.sfs) printf '3962000\t%s\n' "$path" ;;
    *) printf '64\t%s\n' "$path" ;;
  esac
done
EOF
chmod +x "$fixture/bin/du"

echo "MemAvailable:    7654604 kB" >"$fixture/meminfo"
reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst' ]] \
  || fail "8 GiB machine failed to warm a 3.8 GiB root image: $(paste -sd, <<<"$reads")"

echo "MemAvailable:    3670016 kB" >"$fixture/meminfo"
reads=$(warm_reads finished)
[[ -z $reads ]] \
  || fail "4 GiB machine warmed an image larger than its budget: $(paste -sd, <<<"$reads")"

echo "warm offline mirror tests passed"
