# VM images

VM images are for testing. Users download the release ISO from iso.omarchy.org.

A VM image is Omarchy already installed, as one `.qcow2` file. There is an image of the edge channel, rebuilt every night, and an image of the latest release. Its first boot makes it a new machine, with a new machine ID and new SSH host keys. `vm-boot` and `snapshot=on` make every boot a first boot.

The user is `omarchy` and the password is `omarchy`. SSH takes keys only.

## Boot the image by itself

The image boots through UEFI with no other file. Run these commands on a Linux machine with QEMU, read and write access to `/dev/kvm`, `curl` and `jq`:

```bash
latest=https://nightly.omarchy.org/edge/latest.json    # or .../stable/latest.json
image=$(curl -fsSL "$latest" | jq -r .vm.url)
curl -fLO "$image"
curl -fsSLO "$image.sha256"
sha256sum -c "${image##*/}.sha256"

cp /usr/share/edk2/x64/OVMF_VARS.4m.fd vars.fd
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file="${image##*/}",if=virtio,snapshot=on \
  -device virtio-vga
```

The firmware paths are Arch's. `snapshot=on` keeps the downloaded image unchanged. The image is a 4 to 5 GB download.

## Boot it faster, with SSH

The `unpacked/` folder next to each image holds what a direct boot needs:

| File | What it is |
| --- | --- |
| `vmlinuz`, `initrd`, `cmdline` | The image's own kernel, initramfs and kernel arguments. |
| `vm-boot` | A script that boots the image directly into its kernel and gives it an SSH key. |
| `SHA256SUMS` | Checksums of the files above. |

A direct boot skips the firmware and the boot loader: SSH answers after about 6 seconds instead of about 20. Download the folder next to the image, then run `vm-boot`. It also needs `qemu-img` and `ssh`:

```bash
unpacked=$(curl -fsSL "$latest" | jq -r .vm.unpacked)
for file in $(curl -fsSL "$latest" | jq -r '.vm.unpacked_files[]'); do curl -fsSLO "$unpacked$file"; done
sha256sum -c SHA256SUMS
chmod +x vm-boot

./vm-boot "${image##*/}"             # boots, prints how to log in, runs until Ctrl-C
./vm-boot "${image##*/}" uname -r    # boots, runs the command over SSH, powers off
```

`vm-boot` makes a new SSH key for each boot. It runs the machine on an overlay under `/var/tmp`, so the downloaded image is never changed, and deletes the overlay on exit. Set `VM_STATE_DIR` to put the overlay somewhere else.

To get the URL of the edge ISO, run `jq -r .url` on the same `latest.json`.

## Give it your own SSH key

The image holds no SSH key. The VM manager gives the keys to each boot in an SMBIOS type 11 string. The string carries the systemd credential [`tmpfiles.extra`](https://www.freedesktop.org/software/systemd/man/latest/systemd.system-credentials.html). `vm-boot` uses this channel, and any VM manager that can set an SMBIOS type 11 string can use it too.

The last block of each part below is complete. Paste it into a shell and it ends in an SSH login to the new machine. It makes a key pair for the machine, `omarchy-vm` and `omarchy-vm.pub`, in the current folder. Both blocks use the stable image. For edge, change `stable` to `edge` in the first line.

### With QEMU

This boots through UEFI, with a window for the desktop. `snapshot=on` keeps the downloaded image unchanged, so every boot is a fresh machine. The firmware paths are Arch's. On Arch, install what it needs first:

```bash
sudo pacman -S --needed qemu-desktop edk2-ovmf jq openssh
```

```bash
latest=https://nightly.omarchy.org/stable/latest.json
image=$(curl -fsSL "$latest" | jq -r .vm.url)
if [ ! -f "${image##*/}" ]; then
  curl -fL -o download.qcow2 "$image"
  echo "$(curl -fsSL "$image.sha256" | cut -d' ' -f1)  download.qcow2" | sha256sum -c && mv download.qcow2 "${image##*/}"
fi

[ -f omarchy-vm ] || ssh-keygen -q -t ed25519 -N '' -C omarchy-vm -f omarchy-vm
keys=$(base64 -w0 omarchy-vm.pub)
credential=io.systemd.credential.binary:tmpfiles.extra=$(printf 'd /home/omarchy/.ssh 0700 omarchy omarchy -\nf+~ /home/omarchy/.ssh/authorized_keys 0600 omarchy omarchy - %s\n' "$keys" | base64 -w0)

cp /usr/share/edk2/x64/OVMF_VARS.4m.fd vars.fd
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file="${image##*/}",if=virtio,snapshot=on \
  -device virtio-vga \
  -smbios "type=11,value=$credential" \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 &

ssh_opts=(-i omarchy-vm -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
until ssh -n "${ssh_opts[@]}" -o BatchMode=yes -o ConnectTimeout=2 omarchy@127.0.0.1 true 2>/dev/null; do kill -0 $! || break; sleep 2; done
ssh "${ssh_opts[@]}" omarchy@127.0.0.1
```

### With libvirt

This defines a machine named `omarchy` that keeps its disk, in `/var/lib/libvirt/images/omarchy`, across boots. It boots through UEFI, so it boots its own kernel after `omarchy update` installs a new one. Watch its desktop with `virt-viewer -c qemu:///system omarchy` or virt-manager. The firmware paths are Arch's. On Arch, install and start libvirt first. Its default network needs `dnsmasq` and `iptables`:

```bash
sudo pacman -S --needed libvirt qemu-base edk2-ovmf dnsmasq iptables jq openssh virt-viewer
```

```bash
sudo systemctl enable --now libvirtd.service
```

```bash
latest=https://nightly.omarchy.org/stable/latest.json
dir=/var/lib/libvirt/images/omarchy
image=$(curl -fsSL "$latest" | jq -r .vm.url)
sudo mkdir -p "$dir"
if [ ! -f "$dir/omarchy.qcow2" ]; then
  sudo curl -fL -o "$dir/download.qcow2" "$image"
  echo "$(curl -fsSL "$image.sha256" | cut -d' ' -f1)  $dir/download.qcow2" | sha256sum -c && sudo mv "$dir/download.qcow2" "$dir/omarchy.qcow2"
fi

[ -f omarchy-vm ] || ssh-keygen -q -t ed25519 -N '' -C omarchy-vm -f omarchy-vm
keys=$(base64 -w0 omarchy-vm.pub)
credential=io.systemd.credential.binary:tmpfiles.extra=$(printf 'd /home/omarchy/.ssh 0700 omarchy omarchy -\nf+~ /home/omarchy/.ssh/authorized_keys 0600 omarchy omarchy - %s\n' "$keys" | base64 -w0)

cat >omarchy.xml <<EOF
<domain type='kvm'>
  <name>omarchy</name>
  <memory unit='GiB'>4</memory>
  <vcpu>4</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/edk2/x64/OVMF_CODE.4m.fd</loader>
    <nvram template='/usr/share/edk2/x64/OVMF_VARS.4m.fd'/>
    <smbios mode='sysinfo'/>
  </os>
  <sysinfo type='smbios'>
    <oemStrings>
      <entry>$credential</entry>
    </oemStrings>
  </sysinfo>
  <features><acpi/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$dir/omarchy.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'><source network='default'/><model type='virtio'/></interface>
    <video><model type='virtio'/></video>
    <graphics type='vnc'/>
  </devices>
</domain>
EOF
sudo virsh net-info default | grep -q 'Active:.*yes' || sudo virsh net-start default
sudo virsh define omarchy.xml
sudo virsh start omarchy

until ip=$(sudo virsh domifaddr omarchy | awk '/ipv4/ {sub("/.*", "", $4); print $4}'); [ -n "$ip" ]; do sleep 2; done
ssh_opts=(-i omarchy-vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
until ssh -n "${ssh_opts[@]}" -o BatchMode=yes -o ConnectTimeout=2 "omarchy@$ip" true 2>/dev/null; do sleep 2; done
ssh "${ssh_opts[@]}" "omarchy@$ip"
```

### What the credential holds

For another VM manager, pass the same SMBIOS type 11 string. It is the credential's name and the base64 encoding of two [tmpfiles.d](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html) lines. The first line creates `~/.ssh`. The second line writes `authorized_keys` from its base64 encoding, so one credential can carry several keys:

```
d /home/omarchy/.ssh 0700 omarchy omarchy -
f+~ /home/omarchy/.ssh/authorized_keys 0600 omarchy omarchy - <the authorized_keys file, base64>
```

To install your own keys in place of `omarchy-vm`, set `keys=$(base64 -w0 ~/.ssh/id_ed25519.pub)` and remove `-i omarchy-vm` from `ssh_opts`.

How the image uses the credential:

- Each boot that carries the credential writes `authorized_keys` again. To change the keys, change the credential and boot again. On a disk that keeps its writes, a boot without the credential keeps the file from the last boot.
- The initrd also reads the credential. It logs `Failed to resolve user 'omarchy'` for both lines, because the initrd has no such user. The installed system then writes the file.
- The first boot takes the machine ID from the VM's SMBIOS UUID, such as a libvirt domain's `<uuid>` or QEMU's `-uuid`. Without a UUID, the ID is random. On a disk that keeps its writes, later boots keep the first ID, even when the UUID changes.
- Omarchy ignores the power button, so `virsh shutdown` does not stop the machine. Run `systemctl poweroff` in the guest, or `virsh destroy` to cut the power.
