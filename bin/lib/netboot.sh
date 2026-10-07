# Shared netboot rig: the TFTP root and NBD export that fake a PXE LAN
# inside QEMU's user-mode networking. Sourced by test/integration.d/
# pxe-test.sh (the scenario) and bin/omarchy-iso-boot-pxe (its hands-on
# twin) so the two can never drift apart — what the test proves is exactly
# what the tool boots.

NBD_PORT=10809 # not configurable: archiso_nbd_srv carries an address only
NBD_PID=""

# The ISO's own boot trees plus the one-line PXELINUX config entry point
# every real deployment writes: PXELINUX looks for pxelinux.cfg/default
# next to lpxelinux.0, and the INCLUDE routes it into the ISO's own config,
# whose whichsys.c32 line detects PXELINUX and switches to the PXE menu.
# Only the boot trees are extracted — the airootfs and the root image stay
# on the ISO and travel over NBD. Rebuilt when the ISO changes, keyed on
# size+mtime: a pathname key would keep serving a previous build's kernel
# and initramfs after a rebuild to the same release/*.iso name.
assemble_tftp_root() {
  local iso="$1" root="$2" stamp
  stamp="$iso $(stat -c '%s %Y' "$iso")"
  if [[ -f "$root/.from-iso" && $(cat "$root/.from-iso") == "$stamp" ]]; then
    return 0
  fi
  rm -rf "$root"
  mkdir -p "$root"
  bsdtar -xf "$iso" -C "$root" boot arch/boot
  # The ISO's read-only modes would block the glue file below.
  chmod -R u+w "$root"
  mkdir -p "$root/boot/syslinux/pxelinux.cfg"
  echo "INCLUDE syslinux.cfg" >"$root/boot/syslinux/pxelinux.cfg/default"
  echo "$stamp" >"$root/.from-iso"
}

# Serve the ISO as the NBD export the initramfs dials back to: name
# 'archiso' on the well-known port, bound to the host loopback — which is
# where the guest's 10.0.2.2 (and therefore the hook's ${pxeserver}) lands.
# Sets NBD_PID; the caller's exit trap owns the kill.
serve_nbd() {
  local iso="$1"
  if [[ -n $(ss -Htln "sport = :$NBD_PORT") ]]; then
    echo "Port $NBD_PORT is already taken (the port nbd-client dials is fixed); stop whatever serves it first." >&2
    return 1
  fi
  qemu-nbd --read-only --persistent --export-name=archiso \
    --bind=127.0.0.1 --port="$NBD_PORT" "$iso" &
  NBD_PID=$!
  sleep 1
  if ! kill -0 "$NBD_PID" 2>/dev/null; then
    NBD_PID=""
    echo "qemu-nbd could not serve 127.0.0.1:$NBD_PORT." >&2
    return 1
  fi
}
