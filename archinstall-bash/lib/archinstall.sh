# shellcheck shell=bash
# Entry point for library use: `source lib/archinstall.sh` and call the
# functions directly (see README.md for the archinstall ↔ bash mapping), or run
# bin/archinstall for the guided flow.

ARCHINSTALL_BASH_VERSION=0.1.0
ARCHINSTALL_LIB_DIR=${ARCHINSTALL_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

for _archinstall_module in log util hardware disk luks config filesystem pacman mirrors locale installer network applications guided; do
  # shellcheck disable=SC1090
  source "$ARCHINSTALL_LIB_DIR/$_archinstall_module.sh"
done
unset _archinstall_module

log_init
