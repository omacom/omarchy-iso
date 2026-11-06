# The autologin shell on tty1 exists to run the installer from ~/.zlogin, not
# to be used, so the global rc files are skipped there. /etc/zsh/zshrc is
# grml's: 120 KB that compiles completions and probes the system before a
# prompt nobody sees, which on the usb2 boot benchmark (40 MB/s, with the
# verify units sharing the stick fairly) stood between the login and the
# installer for 0.9 s. /etc/profile is sourced as /etc/zsh/zprofile would
# have, so the installer's environment is unchanged. Every other console
# keeps the full interactive setup.
if [[ -o login && $TTY == /dev/tty1 ]]; then
  unsetopt GLOBAL_RCS
  emulate sh -c 'source /etc/profile'
fi
