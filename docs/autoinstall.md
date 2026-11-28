# Autoinstall

The [manual's page](https://omarchy.org/manual/unattended-installs/) is the one for users; this is the same feature in full.

The shipped ISO installs itself with no keyboard when it finds its configuration on a second drive. Attach a drive labeled `cidata` alongside the ISO and the installer copies the config off it and skips the configurator; with no such drive, nothing changes and the wizard runs as usual. No rebuild, no extra boot entry.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer already know how to attach one.

## Configuration files

These are the configurator's own output files, so the way to get a starting set is to run one interactive install and copy what it wrote into `/root`.

| File | Required | Purpose |
|------|----------|---------|
| `user_configuration.json` | Yes | archinstall config: disk, hostname, timezone, keyboard |
| `user_credentials.json` | Unless deferred | Username and password hash |
| `defer-provisioning` | No | Empty marker file; stands in for `user_credentials.json` and defers user creation to first boot |
| `user_encrypt_installation.txt` | No | `true` when `user_configuration.json` carries a `disk_encryption` block; defaults to false |
| `authorized_keys` | No | SSH public keys in sshd's own format, one per line |
| `tailscale_authkey` | No | Tailscale auth key; the machine joins your tailnet on first boot |

`user_configuration.json` and either `user_credentials.json` or `defer-provisioning` must be present, or the installer falls back to the configurator. Generate the password hash for `user_credentials.json` with `openssl passwd -6 "yourpassword"`.

Encryption itself is configured by the `disk_encryption` block inside `user_configuration.json`, which names the partitions to encrypt. The passphrase goes at the top level of `user_credentials.json` as `encryption_password`: archinstall reads it there and ignores the copy the configurator writes into the block, so a cidata drive built from an encrypted install should be treated as the secret it is. The flag file must match the configuration: it drives the encrypted install's SDDM autologin and the final boot validation, not the encryption.

`authorized_keys` is the same file sshd reads — copy your own or write one key per line:

```
ssh-ed25519 AAAA... you@host
```

When `authorized_keys` is present, autoinstall installs it as the user's `~/.ssh/authorized_keys`, enables `sshd`, and adds a `ufw allow ssh` rule — a stock Omarchy install ships openssh with the service disabled and its firewall opens neither port 22 nor anything else beyond LocalSend and Docker's DNS. Networking needs nothing extra; NetworkManager is already enabled with DHCP. Password SSH authentication is left at the distro default. An `authorized_keys` with no keys in it fails the install rather than producing a machine nobody can reach.

When `tailscale_authkey` is present (one key, blank lines and `#` comments ignored), the install adds the `tailscale` package from the ISO's bundled mirror — nothing is fetched from the network at install or boot — and stages the join for first boot: the key lands at `/etc/tailscale/authkey` (root-only), `tailscaled` is enabled, ufw allows traffic in on `tailscale0`, and a background unit runs `tailscale up` once the network is actually up, retrying until it succeeds without holding up the boot. After a successful join the key is deleted and the unit disables itself; until then both survive reboots, so a machine installed offline joins whenever it first gets connectivity. The node appears on the tailnet under the configured hostname. Use a reusable, pre-authorized (tagged) key so one drive image serves many machines — or an ephemeral key for disposable VMs.

The region follows `timezone`, exactly as in an interactive install and as the runtime's `docs/regions.md` defines it: a timezone listed in one of the runtime's region profiles (`default/regions/*/timezones`, such as `Asia/Shanghai` for `cn`) selects that profile, Hong Kong, Macau and Taiwan are always global, and any other timezone keeps the media's region: a preset's `region`, or global on the standard ISO. The installer's language plays no part. Set `omarchy_install.region` in `user_configuration.json` to pick one explicitly, for example `"global"` to keep the default mirrors regardless of timezone. An override naming a profile this ISO does not carry is rejected before any disk operation.

A deferred-provisioning install has no owner timezone yet, so it takes the media's region, or the one `region` names. Unless `region` is set, it also writes the media's region as `REGION=` in the target's `/etc/omarchy/form-defaults`, and first-boot setup settles it against the owner's timezone by the same rule. The installer writes the region marker after unpacking the shared root image; the runtime's finalizers then apply the profile's mirrors, web apps and starting theme. A profile adds no packages or extra repositories — its mirrors serve the same repositories — so a regional install needs no extra packages or network either. Current regional mirrors are x86-only: ARM records the selected region but keeps its platform's original channel templates.

## Building the drive

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata/
```

## Proxmox example

```bash
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:40,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 --vga virtio --serial0 socket \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --ide3 local:iso/cidata.iso,media=cdrom \
  --boot order='scsi0;ide2'

qm start 101
```

Boot order is disk first: the empty disk falls through to the ISO on the first boot, and the installed system boots from disk afterwards. The machine reboots into Omarchy on its own when the install finishes.

Encrypted autoinstalls are not fully unattended — the LUKS passphrase prompt still needs someone at the first boot.

`omarchy_install.language` in `user_configuration.json` takes a code from Omarchy's language registry, like `da` or `ja`, and becomes the installed system's language. Leave it out, or set `en`, for English.
