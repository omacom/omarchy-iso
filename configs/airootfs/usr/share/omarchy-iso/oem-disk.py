"""Choose an unambiguous internal disk for the OEM full-disk install."""

import json
import subprocess
import sys
from pathlib import Path


MIN_DISK_BYTES = 32 * 1024**3


def descendants(device):
    yield device
    for child in device.get("children", []):
        yield from descendants(child)


def select_disk(devices, sysfs=Path("/sys/block")):
    candidates = []
    for device in devices:
        if device.get("type") != "disk":
            continue
        if device.get("ro") or device.get("rm") or device.get("hotplug"):
            continue
        subsystems = set((device.get("subsystems") or "").split(":"))
        # Software/network block devices have no local hardware ancestry.
        if not subsystems.intersection({"pci", "platform"}):
            continue
        if subsystems.intersection({"usb", "firewire"}):
            continue
        if device.get("tran") not in {None, "ata", "sata", "sas", "spi", "nvme", "virtio", "mmc"}:
            continue
        if int(device.get("size") or 0) < MIN_DISK_BYTES:
            continue
        # Includes the ISO itself, Ventoy, mounted filesystems and active swap.
        if any(any(node.get("mountpoints") or []) for node in descendants(device)):
            continue
        if "mmc" in subsystems or device.get("tran") == "mmc":
            try:
                card_type = (sysfs / Path(device["path"]).name / "device/type").read_text().strip()
            except OSError as error:
                raise ValueError(f"Cannot identify MMC card type for {device['path']}") from error
            if card_type == "SD":
                continue
            if card_type != "MMC":
                raise ValueError(f"Unknown MMC card type for {device['path']}: {card_type}")
        candidates.append(device["path"])
    if len(candidates) != 1:
        raise ValueError(
            "OEM install requires exactly one writable, unmounted internal disk "
            f"of at least 32 GiB; found {len(candidates)}: {', '.join(candidates) or 'none'}. "
            "No disk has been changed. Disconnect extra internal disks and boot again."
        )
    return candidates[0]


def main():
    subprocess.run(["udevadm", "settle"], check=True)
    result = subprocess.run(
        ["lsblk", "--json", "--tree", "--bytes", "--output",
         "PATH,TYPE,SIZE,RO,RM,HOTPLUG,TRAN,SUBSYSTEMS,MOUNTPOINTS"],
        check=True, capture_output=True, text=True,
    )
    print(select_disk(json.loads(result.stdout)["blockdevices"]))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"OEM install stopped: {error}")
