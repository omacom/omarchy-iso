# OEM ISO

Build factory installation media with `./bin/omarchy-iso-make --oem --edge --no-boot-offer` (drop `--edge` for the stable channel). The output is named `omarchy-oem-<date>-<architecture>-<ref>.iso`, separate from the ordinary interactive ISO, and `omarchy-iso-release` never publishes one. Add the usual architecture options when needed.

Booting this ISO immediately erases and installs onto the sole eligible internal disk, without a wizard, credentials, a cidata drive, or any key presses. It keeps the install dashboard, uses the encrypted full-disk "for another user" flow, and reboots automatically after a successful install. The next boot runs the existing owner setup, where the owner chooses their account, password, language, keyboard and timezone, and the hostname is made from their username and the machine (`dhh-dell-xps14`). Installation defaults are English, US keyboard, UTC and hostname `omarchy`.

An eligible disk is writable, unmounted, neither removable nor hotplug, not connected by USB or FireWire, and at least 32 GiB. Mounted descendants, including the boot medium and active swap, exclude the entire disk. If zero or multiple eligible disks exist, installation stops without changing any disk; disconnect extra internal disks before trying again. Existing unmounted partitions on the selected disk are erased. Configure firmware to boot the internal disk before the installation medium so the completed machine boots into owner setup instead of reinstalling from the OEM ISO.

## The OEM's branding, agreement and setup scripts

An OEM ISO can carry what its maker wants the machine's owner to see at first boot, and scripts for the factory install to run:

```bash
./bin/omarchy-iso-make --oem --edge --no-boot-offer \
  --oem-config acme/oem.json \
  --oem-script acme/support-info.sh --oem-script acme/owner-defaults.sh
```

`--oem-config` takes a JSON file. Only `name` is required, and paths are relative to the file:

```json
{
  "name": "Acme Computers",
  "logo": "logo.txt",
  "tagline": "Acme Book 14, powered by Omarchy",
  "color": "#ff9e64",
  "eula": {
    "title": "Acme Computers License Agreement",
    "file": "eula.txt"
  }
}
```

| Key | What first-boot setup does with it |
| --- | --- |
| `name` | Names the OEM: in the title of an agreement that has none of its own, and in the record of its acceptance. |
| `logo` | A text file, drawn in place of the Omarchy logo on setup's opening screen and on the agreement. The steps between keep Omarchy's. |
| `tagline` | One line under the logo on setup's opening screen, in place of Omarchy's. |
| `color` | That logo's colour, as `#RRGGBB`. Omarchy's green without it. |
| `eula.file` | The agreement's text. With it, accepting the agreement is setup's last question. |
| `eula.title` | The heading the agreement is shown under. |

First-boot setup runs in kmscon before there is a desktop (using the same terminal launcher as the installer), and falls back to the Linux console if run directly on a plain VT. So a logo is text art, not an SVG or a PNG: at most 81 columns by 12 rows, drawn with ASCII, the characters `▀ ▄ █ ░ ▒ ▓ ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼` (the Omarchy logo uses the first three), or braille dots (`⠁` to `⣿`), which give four times the detail. `chafa` draws an image either way; add `--invert` for dark artwork on a light or transparent background:

```bash
chafa --format symbols --symbols braille --colors none --size 81x12 logo.svg >logo.txt             # dots
chafa --format symbols --symbols vhalf+solid+space --colors none --size 81x12 logo.svg >logo.txt   # blocks
```

To stay drawable on a plain Linux console too, `builder/oem-bundle.py` still enforces the 512-glyph Terminus console font limits: a logo takes at most 128 different braille patterns, and they and the characters beyond ASCII in the bundle's text come to at most 256 (on a plain VT, setup draws those dot patterns into the console font while a branded screen is up).

The agreement is UTF-8 text in what that console font covers: Latin, Greek and Cyrillic, with their punctuation. Setup wraps it to its column. `builder/oem-bundle.py` checks the whole bundle before the build starts and names the first character it rejects, so a mistake stops the build and not a machine's first boot.

The agreement comes after the owner has reviewed their account and before anything is created. It scrolls with the arrow, Page Up, Page Down, Home and End keys, with Accept in focus. Declining offers to shut the machine down, with going back to the agreement in focus; a machine whose owner declines is left as it was shipped, and asks again at its next boot. Accepting records the OEM's name, the SHA-256 of the text, the account and the time in `/var/lib/omarchy/oem/eula-accepted.json`. Showing all of it needs a runtime with `install/provisioning/oem.sh`; the install stops if the one this ISO bundles lacks it.

Each `--oem-script` is a bash script the install runs once, as root, in the new system (a chroot, with no services running), in the order given. They run after Omarchy has configured the system and built its boot files, and before the boot checks and the factory snapshot, so a factory reset returns to the machine as they left it. A script that exits non-zero fails the install, at the factory. So does one that leaves `/etc/omarchy/oem` other than the build checked it: the branding and the agreement are the config's to set, not a script's. The system's pacman is by then set to its online repositories, so a script can install packages only where the factory has a network.

[`test/unit/fixtures/oem/`](../test/unit/fixtures/oem/) is a complete bundle.
