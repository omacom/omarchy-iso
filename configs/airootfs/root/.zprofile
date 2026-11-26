# On tty1 autologin, skip /etc/zsh/zshrc (120 KB grml-zsh-config + compinit,
# ~1.3 s on live boot) so /root/.zlogin launches ~/.automated_script.sh right
# away. /etc/zsh/zprofile has already sourced /etc/profile; other VTs and SSH
# keep the full interactive zsh configuration.
if [[ -o login && -t 0 && $(tty 2>/dev/null) == /dev/tty1 ]]; then
  setopt NO_GLOBAL_RCS
fi
