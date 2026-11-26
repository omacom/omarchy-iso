# shellcheck shell=sh
# The live boot hides the console's cursor (vt.global_cursor_default=0) so
# nothing blinks before the installer draws on tty1. A shell on another VT
# wants it.
case $(tty 2>/dev/null) in
  /dev/tty1) ;;
  /dev/tty[0-9]*) printf '\033[?25h' ;;
esac
