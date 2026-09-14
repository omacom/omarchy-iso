# What every writer strips before a line may enter the unified install log
# (/var/log/omarchy-install.log). Two consumers, one filter: the dashboard
# runs the orchestrator child's output through it, and run-phase runs each
# phase unit's output through it -- the archinstall-bash banners below come
# from installer functions that now run inside omarchy-install-base.service,
# so filtering only the child's stream would let them through.
#
# The banners go because archinstall-bash is a library subsystem here: its
# completion banner would read as "done" after an Omarchy failure in a later
# phase, which makes the support log contradictory. The library's own log
# (/var/log/archinstall/install.log) still carries them.

# Terminal control sequences: the log is a file, not a terminal.
s/\x1b\[[0-9;?]*[A-Za-z]//g

/^ *Activating systemd-timesyncd for time synchronization using Arch Linux and ntp.org NTP servers$/d
/^ *Enabling service systemd-timesyncd$/d
/^ *Setting password for root$/d
/^ *Updating \/mnt\/etc\/fstab$/d
/^ *Syncing the system\.\.\.$/d
/^ *Installation completed without any errors\.$/d
/^ *Log files temporarily available at \/var\/log\/archinstall\.$/d
/^ *You may reboot when ready\.$/d
