#!/usr/bin/ash
# Run with mkinitcpio's BusyBox ash; second argument is its init_functions file.
set -eu
runtime=${1:?runtime hook}
init_functions=${2:?mkinitcpio init_functions}
enabled=1
reports=0
calls=0
grep() { return "$enabled"; }
sed() {
    if [ "$#" = 3 ] && [ "$3" = /init_functions ]; then
        command sed "$1" "$2" "$init_functions"
    else
        command sed "$@"
    fi
}
launch_interactive_shell() { calls=$((calls + 1)); }
. "$runtime"

# Normal boot must not change shell behavior.
run_earlyhook
launch_interactive_shell
[ "$calls" = 1 ]
! type dragon_original_shell >/dev/null 2>&1

# Diagnostic mode must report before delegating and retain arguments/status.
enabled=0
run_earlyhook
dragon_boot_report() { reports=$((reports + 1)); }
dragon_original_shell() {
    [ "$reports" = 1 ] && [ "$#" = 1 ] && [ "$1" = --exec ] || exit 1
    return 17
}
result=0
launch_interactive_shell --exec || result=$?
[ "$result" = 17 ]
echo 'PASS: diagnostic gating, report ordering, shell arguments and status'
