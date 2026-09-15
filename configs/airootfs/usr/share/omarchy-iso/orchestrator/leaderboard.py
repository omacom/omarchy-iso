"""The install timing artifact, as the leaderboard will read it.

phases.run() records what happened; this module turns that record into a
document that can be classed and compared: which medium ran the install, the
class the installer observed (never one the user picks), a sketch of the
hardware, and a seal over the exact bytes written.

The seal is an Ed25519 keypair generated in the live environment once the
phase loop has succeeded. Only the public key and a detached signature land on
the target; the private key lives in this process for the length of one
openssl call, is passed over a pipe, and is never written anywhere. Editing the
document after the install breaks the signature and no key exists to re-sign
it. That makes the result tamper-evident. It does not make it true: anyone can
fabricate a document and a keypair on any machine, so the words "verified" and
"cheat-proof" are deliberately absent here. Classes, plausibility checks and a
human at the top of the board are what handle that.

Nothing in this module may fail the install. Every probe is best effort and
logs instead of raising; the worst case is a timing file that says less.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Callable

from .context import InstallContext
from .ui import info

# Where the sealed result lives on the installed system. The dashboard and the
# acceptance harness still read the copy at TIMING_LOG; both files hold the
# same bytes and the signature is over those bytes.
ARTIFACT_DIR = Path("var/lib/omarchy/leaderboard")
TIMING_LOG = Path("var/log/omarchy-install-timing.json")
DOCUMENT_NAME = "timing.json"
SIGNATURE_NAME = "timing.sig"
PUBLIC_KEY_NAME = "install.pub"

# The live environment's root. Tests point this at a fixture tree.
LIVE_ROOT = Path("/")
ISO_REF_FILE = Path("root/omarchy_iso_ref")
ISO_MIRROR_FILE = Path("root/omarchy_mirror")
BUILD_INFO_FILE = Path("usr/share/omarchy-iso/build-info")
OFFLINE_DB_FILE = Path("var/cache/omarchy/mirror/offline/offline.db.tar.gz")
ARCHISO_BOOT_MOUNT = Path("run/archiso/bootmnt")
DMI_DIR = Path("sys/class/dmi/id")

# Package names whose version identifies the Omarchy release on the target.
RELEASE_PACKAGES = ("omarchy", "omarchy-dev", "omarchy-rc")


def finalize(ctx: InstallContext, state: dict) -> dict:
    """Build, seal and write the timing artifact. Returns the document written.

    `state` is the live phase-loop record. It is not modified; the dashboard
    keeps polling its own copy.
    """
    document = dict(state)
    document["iso"] = _best_effort("ISO identity", lambda: describe_iso())
    document["release"] = _best_effort("release", lambda: describe_release(ctx.target))
    document["class"] = _best_effort("install class", lambda: describe_class(ctx))
    document["hardware"] = _best_effort("hardware", lambda: describe_hardware(ctx))
    document["live"] = _best_effort("live environment", lambda: describe_live())
    # Reserved for a hardware-backed witness (a TPM quote over the document
    # hash) once measured boot of the live medium is something a server can
    # check against. Null until then, so schema 1 readers already know the slot.
    document["attestation"] = None

    keypair = _best_effort("seal keypair", generate_keypair)
    if keypair is not None:
        document["seal"] = {
            "algorithm": "ed25519",
            "public_key": _spki_base64(keypair.public_pem),
        }
    else:
        document["seal"] = None

    # The document goes to disk first and the signature is made over that
    # file, so the bytes sealed are the bytes a reader will find.
    document_path = _write_document(ctx.target, _serialize(document))
    signature = None
    if keypair is not None:
        signature = _best_effort("seal signature", lambda: sign(keypair.private_pem, document_path))
        if signature is None:
            document["seal"] = None
            document_path = _write_document(ctx.target, _serialize(document))
    public_pem = keypair.public_pem if signature is not None else None
    keypair = None  # the private key is not needed past this point

    _write_seal(ctx.target, signature, public_pem)
    _best_effort("factory copy", lambda: copy_into_factory(ctx))
    return document


# ---------------------------------------------------------------------------
# Identity: the medium and the release


def describe_iso() -> dict:
    """What the ISO says about itself. The offline database hash is the part a
    server can allow-list per published ISO; the refs are what a human reads."""
    iso = {
        "ref": _read_live(ISO_REF_FILE),
        "mirror": _read_live(ISO_MIRROR_FILE),
        "offline_db_sha256": _sha256_live(OFFLINE_DB_FILE),
        "build": _parse_build_info(_read_live(BUILD_INFO_FILE)),
    }
    return iso


def describe_release(target: Path) -> dict | None:
    """The Omarchy package version that was installed, read from the target's
    pacman database. This is the release a board is kept per."""
    local_db = target / "var" / "lib" / "pacman" / "local"
    try:
        entries = sorted(os.listdir(local_db))
    except OSError:
        return None
    for entry in entries:
        if not entry.startswith("omarchy"):
            continue
        desc = local_db / entry / "desc"
        try:
            fields = _parse_desc(desc.read_text())
        except OSError:
            continue
        if fields.get("NAME") in RELEASE_PACKAGES:
            return {"package": fields["NAME"], "version": fields.get("VERSION")}
    return None


# ---------------------------------------------------------------------------
# Class: what the installer observed


def describe_class(ctx: InstallContext) -> dict:
    """The class tuple. Every field is something the installer saw for itself;
    none is a label the user chose. "Official" is decided server-side from this
    tuple plus the ISO allow-list, never asserted here."""
    from .phases_impl import _provision_install_encrypted

    return {
        "mode": ctx.mode,
        "encrypted": bool(_provision_install_encrypted(ctx)),
        "virt": _detect_virt(),
        "warm": os.environ.get("OMARCHY_NO_PREFETCH") != "1",
    }


def _detect_virt() -> str:
    # systemd-detect-virt exits non-zero for "none"; the word is still the answer.
    out = _command_output(["systemd-detect-virt"], accept_failure=True)
    return (out or "none").strip() or "none"


# ---------------------------------------------------------------------------
# Hardware: enough to place a result, nothing that identifies a person


def describe_hardware(ctx: InstallContext) -> dict:
    """Vendor, product, CPU, memory and the two disks that bound the install.
    Never a hostname, serial, MAC address, disk UUID or username."""
    return {
        "vendor": _read_live(DMI_DIR / "sys_vendor"),
        "product": _read_live(DMI_DIR / "product_name"),
        "product_version": _read_live(DMI_DIR / "product_version"),
        "board": _read_live(DMI_DIR / "board_name"),
        "cpu": _cpu_model(),
        "cpus": os.cpu_count(),
        "memory_kb": _meminfo_total_kb(),
        "target_disk": _disk_behind(_mount_source(ctx.target)),
        "install_medium": _disk_behind(_mount_source(LIVE_ROOT / ARCHISO_BOOT_MOUNT)),
    }


def _cpu_model() -> str | None:
    text = _read_live(Path("proc/cpuinfo"))
    if not text:
        return None
    for line in text.splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return None


def _meminfo_total_kb() -> int | None:
    text = _read_live(Path("proc/meminfo"))
    if not text:
        return None
    match = re.search(r"^MemTotal:\s+(\d+)\s+kB", text, re.MULTILINE)
    return int(match.group(1)) if match else None


def _mount_source(path: Path) -> str | None:
    out = _command_output(["findmnt", "-no", "SOURCE", str(path)])
    if not out:
        return None
    # "/dev/mapper/root[/@]" names a subvolume; the device is before the bracket.
    return out.strip().split("[")[0] or None


def _disk_behind(device: str | None) -> dict | None:
    """Walk from a partition or dm-crypt mapping down to the disk that holds it.
    lsblk -s prints the inverse tree, so the deepest node of type disk is the
    physical device; a loop device (Ventoy, an ISO on a disk) has no disk under
    it and is reported as what it is."""
    if not device:
        return None
    out = _command_output(["lsblk", "-sJ", "-o", "NAME,TYPE,MODEL,TRAN,ROTA,SIZE", device])
    if not out:
        return None
    try:
        nodes = json.loads(out).get("blockdevices") or []
    except ValueError:
        return None
    node = nodes[0] if nodes else None
    last = node
    while node:
        last = node
        if node.get("type") == "disk":
            break
        children = node.get("children") or []
        node = children[0] if children else None
    if not last:
        return None
    return {
        "type": last.get("type"),
        "model": (last.get("model") or None),
        "transport": last.get("tran"),
        "rotational": _as_bool(last.get("rota")),
        "size": last.get("size"),
    }


# ---------------------------------------------------------------------------
# Live environment


def describe_live() -> dict:
    """How long the medium had been up before the result was sealed, and what
    kernel ran it. Cheap plausibility context for a reviewer."""
    uptime = _read_live(Path("proc/uptime"))
    seconds = None
    if uptime:
        try:
            seconds = float(uptime.split()[0])
        except (ValueError, IndexError):
            seconds = None
    return {"uptime_s": seconds, "kernel": os.uname().release}


# ---------------------------------------------------------------------------
# Seal


class Keypair:
    __slots__ = ("private_pem", "public_pem")

    def __init__(self, private_pem: bytes, public_pem: bytes):
        self.private_pem = private_pem
        self.public_pem = public_pem


def generate_keypair() -> Keypair:
    """An Ed25519 keypair that exists only in this process. openssl writes the
    private key to its stdout, which is our pipe; no path is ever involved."""
    private_pem = subprocess.run(
        ["openssl", "genpkey", "-algorithm", "ed25519"],
        check=True, capture_output=True,
    ).stdout
    public_pem = subprocess.run(
        ["openssl", "pkey", "-pubout"],
        input=private_pem, check=True, capture_output=True,
    ).stdout
    if b"PRIVATE KEY" not in private_pem or b"PUBLIC KEY" not in public_pem:
        raise RuntimeError("openssl did not produce an Ed25519 keypair")
    return Keypair(private_pem, public_pem)


def sign(private_pem: bytes, document_path: Path) -> bytes:
    """Detached Ed25519 signature over the file at document_path. The key
    reaches openssl on stdin and nowhere else."""
    result = subprocess.run(
        ["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", "/dev/stdin", "-in", str(document_path)],
        input=private_pem, capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"openssl pkeyutl failed: {result.stderr.decode(errors='replace').strip()}")
    if len(result.stdout) != 64:
        raise RuntimeError(f"unexpected Ed25519 signature length {len(result.stdout)}")
    return result.stdout


def verify(public_pem_path: Path, document_path: Path, signature_path: Path) -> bool:
    """Reference verification with nothing but openssl. The installed system's
    CLI and the tests both check the seal this way."""
    result = subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-rawin",
         "-inkey", str(public_pem_path), "-in", str(document_path),
         "-sigfile", str(signature_path)],
        capture_output=True,
    )
    return result.returncode == 0


def _spki_base64(public_pem: bytes) -> str:
    body = b"".join(
        line.strip() for line in public_pem.splitlines()
        if line and not line.startswith(b"-----")
    )
    return body.decode()


# ---------------------------------------------------------------------------
# Writing


def _serialize(document: dict) -> bytes:
    # Same shape phases._write_state uses for the live state, so a reader of
    # either file sees one format. Trailing newline so the file ends like a file.
    return (json.dumps(document, indent=2, default=str) + "\n").encode()


def _write_document(target: Path, payload: bytes) -> Path:
    """The document, at its home and at the path the dashboard and the test
    harness already read. Same bytes in both; the seal is over the first."""
    artifact_dir = target / ARTIFACT_DIR
    artifact_dir.mkdir(parents=True, exist_ok=True)
    document_path = artifact_dir / DOCUMENT_NAME
    _write_bytes(document_path, payload)
    timing_log = target / TIMING_LOG
    timing_log.parent.mkdir(parents=True, exist_ok=True)
    _write_bytes(timing_log, payload)
    return document_path


def _write_seal(target: Path, signature: bytes | None, public_pem: bytes | None) -> None:
    artifact_dir = target / ARTIFACT_DIR
    for name in (SIGNATURE_NAME, PUBLIC_KEY_NAME):
        try:
            (artifact_dir / name).unlink()
        except FileNotFoundError:
            pass
    if signature is not None and public_pem is not None:
        _write_bytes(artifact_dir / SIGNATURE_NAME, signature)
        _write_bytes(artifact_dir / PUBLIC_KEY_NAME, public_pem)
        info("› sealed install timing (ed25519)")
    else:
        info("› install timing written unsealed")


def _write_bytes(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    tmp.replace(path)


def copy_into_factory(ctx: InstallContext) -> None:
    """Carry the sealed result into the @factory snapshot so a factory reset
    keeps the machine's original result. create_factory_snapshot ran as the
    last phase, before this file existed, so the snapshot is reopened for the
    length of one copy."""
    from .phases_impl import _findmnt_value

    if _findmnt_value(ctx.target, "FSTYPE") != "btrfs":
        return
    device = (_findmnt_value(ctx.target, "SOURCE") or "").split("[")[0]
    if not device:
        return

    top = ctx.state_dir / "factory-top"
    top.mkdir(parents=True, exist_ok=True)
    subprocess.run(["mount", "-o", "subvolid=5", device, str(top)], check=True)
    try:
        factory = top / "@factory"
        if not factory.is_dir():
            return
        subprocess.run(["btrfs", "property", "set", "-ts", str(factory), "ro", "false"], check=True)
        try:
            for relative in (ARTIFACT_DIR / DOCUMENT_NAME, ARTIFACT_DIR / SIGNATURE_NAME,
                             ARTIFACT_DIR / PUBLIC_KEY_NAME, TIMING_LOG):
                source = ctx.target / relative
                if not source.is_file():
                    continue
                destination = factory / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read_bytes())
        finally:
            subprocess.run(["btrfs", "property", "set", "-ts", str(factory), "ro", "true"], check=True)
    finally:
        subprocess.run(["umount", str(top)], check=False, capture_output=True)


# ---------------------------------------------------------------------------
# Small helpers


def _best_effort(what: str, fn: Callable[[], object]):
    try:
        return fn()
    except Exception as exc:  # noqa: BLE001 — a timing detail never fails an install
        info(f"› leaderboard: {what} unavailable: {exc}")
        return None


def _command_output(cmd: list[str], *, accept_failure: bool = False) -> str | None:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    except OSError:
        return None
    if result.returncode != 0 and not accept_failure:
        return None
    return result.stdout


def _read_live(relative: Path) -> str | None:
    try:
        return (LIVE_ROOT / relative).read_text().strip()
    except OSError:
        return None


def _sha256_live(relative: Path) -> str | None:
    try:
        with open(LIVE_ROOT / relative, "rb") as fh:
            digest = hashlib.sha256()
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except OSError:
        return None


def _parse_build_info(text: str | None) -> dict | None:
    if not text:
        return None
    build: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip():
            build.setdefault(key.strip(), value.strip())
    return build or None


def _parse_desc(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("%") and line.endswith("%"):
            current = line.strip("%")
        elif current and line and current not in fields:
            fields[current] = line.strip()
    return fields


def _as_bool(value) -> bool | None:
    if value in (True, False):
        return value
    if value in ("1", 1):
        return True
    if value in ("0", 0):
        return False
    return None
