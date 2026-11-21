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
#   mirror    omarchy-mirror-verify.service hashing; the image's start job
#             queued behind it (Before=), so that unit is still inactive
#   image     the mirror check finished, the image hashing
#   finished  both checks finished, no jobs left
cat >"$fixture/bin/systemctl" <<EOF
#!/bin/bash
mapfile -t phases <"$fixture/phases"
phase=\${phases[0]}
((\${#phases[@]} == 1)) || printf '%s\n' "\${phases[@]:1}" >"$fixture/phases"
echo "\$phase" >"$fixture/now"
case "\$1 \$phase" in
  "is-active mirror")   [[ \$* == *omarchy-mirror-verify* ]] && echo activating || echo inactive ;;
  "is-active image")    [[ \$* == *omarchy-mirror-verify* ]] && echo active || echo activating ;;
  "is-active finished") echo active ;;
  "list-jobs mirror")
    echo "1 omarchy-mirror-verify.service     start running"
    echo "2 omarchy-root-image-verify.service start waiting" ;;
  "list-jobs image")  echo "2 omarchy-root-image-verify.service start running" ;;
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

reads=$(warm_reads mirror mirror image image finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst' ]] \
  || fail "the warm-up read the medium before both checks had finished: $(paste -sd, <<<"$reads")"

reads=$(warm_reads finished)
[[ $reads == $'finished omarchy-root.sfs\nfinished linux-firmware-1-1-any.pkg.tar.zst' ]] \
  || fail "the warm-up does not read the medium once the checks are done: $(paste -sd, <<<"$reads")"

echo "warm offline mirror tests passed"
