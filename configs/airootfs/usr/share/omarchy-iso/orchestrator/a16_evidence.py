"""Save the experimental A16 install identity and arm one local boot capture."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil


def stage_evidence(target: Path, esp: Path, live: Path = Path("/"), *, kernel: str = "linux-omarchy") -> None:
    if kernel != "linux-omarchy":
        raise RuntimeError(f"Unsupported A16 kernel package: {kernel}")
    state = target / "var/lib/omarchy/a16-evidence"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    share = live / "usr/share/omarchy-iso"
    assets = [
        (live / "usr/local/bin/omarchy-a16-evidence", "usr/local/bin/omarchy-a16-evidence", 0o755),
        (share / "omarchy-a16-first-boot-evidence", "usr/local/sbin/omarchy-a16-first-boot-evidence", 0o755),
        (share / "omarchy-a16-evidence.service", "etc/systemd/system/omarchy-a16-evidence.service", 0o644),
        (share / "build-info", "usr/share/omarchy-iso/build-info", 0o644),
    ]
    for source, relative, mode in assets:
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(mode)

    kernels = [path for path in (target / "usr/lib/modules").glob("*/vmlinuz")
               if (path.parent / "pkgbase").is_file() and
               (path.parent / "pkgbase").read_text().strip() == kernel]
    dtbs = list((target / f"boot/dtbs/{kernel}").rglob("*zenbook-a16*.dtb"))
    ukis = list((esp / "EFI/Linux").glob(f"*_{kernel}.efi"))
    ukis += list((esp / "EFI/Linux").glob(f"*_{kernel}-fallback.efi"))
    if not kernels or not dtbs or not ukis:
        raise RuntimeError("A16 install evidence requires the kernel, board DTB and UKI")
    paths = kernels + dtbs + ukis
    paths += [target / "usr/share/omarchy-iso/build-info", esp / "limine.conf"]
    for relative in (f"usr/share/doc/{kernel}/a16-source.json", f"usr/share/doc/{kernel}/kernel-release"):
        metadata = target / relative
        if metadata.is_file():
            paths.append(metadata)
    hashes = {}
    for path in sorted(paths):
        if not path.stat().st_size:
            raise RuntimeError(f"Cannot record an empty A16 boot artifact: {path}")
        with path.open("rb") as stream:
            hashes[str(path.relative_to(target))] = hashlib.file_digest(stream, "sha256").hexdigest()
    receipt = {
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "status": "installer boot checks passed; physical acceptance pending",
        "kernel_package": kernel,
        "sha256": hashes,
    }
    temporary = state / "install-receipt.json.tmp"
    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(state / "install-receipt.json")
    wants = target / "etc/systemd/system/multi-user.target.wants"
    wants.mkdir(parents=True, exist_ok=True)
    link = wants / "omarchy-a16-evidence.service"
    if link.is_symlink():
        link.unlink()
    link.symlink_to("../omarchy-a16-evidence.service")
