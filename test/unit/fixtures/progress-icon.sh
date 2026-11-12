# Stands in for Omarchy's install/provisioning/progress-icon.sh, which
# build-iso.sh vendors into the ISO from the runtime package, so dashboard tests
# run without an Omarchy runtime. They cover the dashboard around the progress
# screen; the screen itself is tested where it lives, in the omarchy repo.
progress_icon_layout() { :; }
progress_icon_static() { :; }
progress_icon_frame() { :; }
progress_icon_finish() { :; }
