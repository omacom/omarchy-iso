#!/bin/bash
#
# omarchy-installer-cpus names the performance cores of a hybrid CPU with at
# least four of them, and nothing on any other machine, and omarchy-iso-install
# moves itself there before it starts the installer.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tool="$ROOT/configs/airootfs/usr/local/bin/omarchy-installer-cpus"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1 (got '${2:-}')" >&2; exit 1; }

# machine NAME CORE_LIST ATOM_LIST "cpu:core_id ..."
machine() {
  local sys="$work/$1" pair
  mkdir -p "$sys/devices/system/cpu"
  if [[ -n $2 ]]; then
    mkdir -p "$sys/devices/cpu_core"
    echo "$2" >"$sys/devices/cpu_core/cpus"
  fi
  if [[ -n $3 ]]; then
    mkdir -p "$sys/devices/cpu_atom"
    echo "$3" >"$sys/devices/cpu_atom/cpus"
  fi
  for pair in $4; do
    mkdir -p "$sys/devices/system/cpu/cpu${pair%%:*}/topology"
    echo "${pair##*:}" >"$sys/devices/system/cpu/cpu${pair%%:*}/topology/core_id"
  done
}
cpus() { OMARCHY_SYS_ROOT="$work/$1" bash "$tool"; }

# Panther Lake H: four P-cores without SMT, twelve E-cores.
machine ptl 0-3 4-15 "0:0 1:1 2:2 3:3"
[[ $(cpus ptl) == 0-3 ]] || fail "four P-cores are named" "$(cpus ptl)"

# Raptor Lake: eight P-cores with SMT, their sixteen CPUs in two ranges.
machine rpl 0-7,16-23 8-15 "0:0 1:1 2:2 3:3 4:4 5:5 6:6 7:7 16:0 17:1 18:2 19:3 20:4 21:5 22:6 23:7"
[[ $(cpus rpl) == 0-7,16-23 ]] || fail "eight P-cores in two ranges are named" "$(cpus rpl)"

# A U-series part: two P-cores with SMT are four CPUs, and still only two cores.
machine adl-u 0-3 4-11 "0:0 1:0 2:4 3:4"
[[ -z $(cpus adl-u) ]] || fail "two P-cores are too few" "$(cpus adl-u)"

# Not hybrid: one kind of core, or no such directories at all (AMD, ARM).
machine p-only 0-7 "" "0:0 1:1 2:2 3:3 4:4 5:5 6:6 7:7"
[[ -z $(cpus p-only) ]] || fail "a CPU with no E-cores is left alone" "$(cpus p-only)"
machine plain "" "" ""
[[ -z $(cpus plain) ]] || fail "a machine that is not hybrid is left alone" "$(cpus plain)"

# A list it cannot read must not pin anything.
machine odd "0-3,x" 4-15 "0:0 1:1 2:2 3:3"
[[ -z $(cpus odd) ]] || fail "an unreadable list pins nothing" "$(cpus odd)"
machine no-topology 0-3 4-15 "0:0 1:1"
[[ -z $(cpus no-topology) ]] || fail "missing topology pins nothing" "$(cpus no-topology)"

for name in ptl rpl adl-u p-only plain odd no-topology; do
  OMARCHY_SYS_ROOT="$work/$name" bash "$tool" >/dev/null || fail "exit status is 0 on $name" "$?"
done

# omarchy-iso-install, with its last line (the installer itself) replaced by a
# report of where it ended up, and taskset and the helper stubbed.
wrapper="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-install"
mkdir -p "$work/bin"
sed '$d' "$wrapper" | sed '/^cd \/usr\/share\/omarchy-iso$/d' >"$work/wrapper"
echo 'echo "pinned=$(cat "$STATE") all=${OMARCHY_INSTALLER_ALL_CPUS:-}"' >>"$work/wrapper"
cat >"$work/bin/taskset" <<'STUB'
#!/bin/bash
# taskset -pc PID prints the affinity; taskset -pc LIST PID sets it, within $CPUSET.
if [[ $1 == -pc && $# == 2 ]]; then
  echo "pid $2's current affinity list: $(cat "$STATE")"
elif [[ $1 == -pc && $# == 3 ]]; then
  [[ $2 == "$REFUSE" ]] && exit 1
  if [[ -n ${CPUSET:-} && $2 == "$PCORES" ]]; then echo "$CPUSET" >"$STATE"; else echo "$2" >"$STATE"; fi
fi
STUB
cat >"$work/bin/omarchy-installer-cpus" <<'STUB'
#!/bin/bash
echo "$PCORES"
STUB
cat >"$work/bin/cat" <<'STUB'
#!/bin/bash
if [[ $1 == /sys/devices/system/cpu/online ]]; then echo "$ONLINE"; else exec /usr/bin/cat "$@"; fi
STUB
chmod +x "$work/bin"/*
wrap() { # start-affinity
  echo "$1" >"$work/state"
  PATH="$work/bin:$PATH" STATE="$work/state" ONLINE=0-15 PCORES="${PCORES-0-3}" CPUSET="${CPUSET:-}" \
    REFUSE="${REFUSE:-}" bash "$work/wrapper"
}

[[ $(wrap 0-15) == "pinned=0-3 all=0-15" ]] || fail "the installer moves to the P-cores and hands on the CPUs it had" "$(wrap 0-15)"
[[ $(PCORES='' wrap 0-15) == "pinned=0-15 all=" ]] || fail "a machine the helper names no cores for is left alone" "$(PCORES='' wrap 0-15)"
[[ $(wrap 4-15) == "pinned=4-15 all=" ]] || fail "an installer someone already narrowed is left where it is" "$(wrap 4-15)"
[[ $(CPUSET=0-1 wrap 0-15) == "pinned=0-15 all=" ]] || fail "a move that did not give it all the P-cores is undone" "$(CPUSET=0-1 wrap 0-15)"
[[ $(REFUSE=0-3 wrap 0-15) == "pinned=0-15 all=" ]] || fail "a move that failed leaves it on every CPU" "$(REFUSE=0-3 wrap 0-15)"
grep -q '^exec python -m orchestrator.main$' "$wrapper" || fail "the wrapper still ends by starting the installer"

echo "ok: the installer runs on the performance cores of a hybrid CPU with four or more"
