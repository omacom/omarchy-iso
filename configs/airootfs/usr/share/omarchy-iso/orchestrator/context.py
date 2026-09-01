"""Install context: parsed configurator output, invocation paths, and a
mutable `state` dict for objects that live across phases (e.g., the
archinstall config handler and mirror list handler)."""

from __future__ import annotations

import json
import os
import platform
import secrets
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Limine ships BOOT{X64,IA32,AA64,RISCV64,LOONGARCH64}.EFI and the Arch package
# installs *all* of them, so hardcoding the x64 name does not fail on ARM -- it
# silently installs an x86-64 binary the firmware cannot execute. Derive the
# name instead, matching limine-common-functions' limine_efi_arch().
_LIMINE_EFI_ARCH = {
    "x86_64": "X64",
    "i686": "IA32",
    "aarch64": "AA64",
    "riscv64": "RISCV64",
    "loongarch64": "LOONGARCH64",
}.get(platform.machine(), "X64")
_LIMINE_SOURCE_EFI = f"BOOT{_LIMINE_EFI_ARCH}.EFI"
_LIMINE_EFI_BINARY = f"limine_{_LIMINE_EFI_ARCH.lower()}.efi"


@dataclass
class InstallContext:
    config_path: Path
    creds_path: Path
    full_name: str
    email: str
    encrypt: bool
    authorized_keys_path: Path | None
    tailscale_authkey_path: Path | None

    user_configuration: dict
    user_credentials: dict
    arch_config_path: Path
    omarchy_install: dict[str, Any]
    defer_provisioning: bool = False

    target: Path = Path("/mnt")
    omarchy_path: Path = Path("/usr/share/omarchy")
    state_dir: Path = Path("/run/omarchy-install")
    log_path: Path = Path("/var/log/omarchy-install.log")
    target_log_path: Path = Path("/mnt/var/log/omarchy-install.log")

    # Mutable per-run state shared across phases (e.g., 'arch_config_handler',
    # 'mirror_handler'). Phases populate as needed; later phases read.
    state: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_env(cls) -> "InstallContext":
        config_str = os.environ.get("OMARCHY_INSTALL_CONFIG")
        creds_str = os.environ.get("OMARCHY_INSTALL_CREDS")
        if not config_str or not creds_str:
            raise RuntimeError("OMARCHY_INSTALL_CONFIG and OMARCHY_INSTALL_CREDS must be set")

        config_path = Path(config_str)
        creds_path = Path(creds_str)
        user_configuration = json.loads(config_path.read_text())
        omarchy_install = user_configuration.get("omarchy_install") or _default_omarchy_install(user_configuration)

        # Deferred provisioning: the whole system installs but user creation is deferred to
        # first boot. Selected by the configurator (omarchy_install.defer_provisioning) or by
        # an `defer-provisioning` marker file on an autoinstall drive, which also replaces the
        # user_credentials.json requirement.
        defer_provisioning_marker = _optional_path(os.environ.get("OMARCHY_INSTALL_DEFER_PROVISIONING_FILE"))
        defer_provisioning = bool(omarchy_install.get("defer_provisioning")) or defer_provisioning_marker is not None
        omarchy_install["defer_provisioning"] = defer_provisioning

        if creds_path.exists():
            user_credentials = json.loads(creds_path.read_text())
        elif defer_provisioning:
            user_credentials = {"users": []}
        else:
            raise RuntimeError(f"credentials file missing: {creds_path}")

        if defer_provisioning:
            # Deferred provisioning promises no account until first boot. A supplied
            # credentials file (a rig handing over its LUKS passphrase) must
            # not smuggle in users or a root password.
            encryption_password = user_credentials.get("encryption_password")
            user_credentials = {"users": []}
            if encryption_password:
                user_credentials["encryption_password"] = encryption_password

        arch_configuration = dict(user_configuration)
        arch_configuration.pop("omarchy_install", None)

        if defer_provisioning:
            # The userless invariant covers the archinstall config too: a
            # combined/legacy config could carry account authentication that
            # archinstall would still act on (users, a root password). Strip
            # every such field so no account is created before first boot.
            _strip_account_fields(arch_configuration)

        state_dir = Path(os.environ.get("OMARCHY_INSTALL_STATE_DIR", "/run/omarchy-install"))
        state_dir.mkdir(parents=True, exist_ok=True)

        if defer_provisioning:
            # Encrypted deferred-provisioning installs have no user password to protect LUKS
            # with. Generate a throwaway passphrase (staged for first-boot
            # re-key by the stage_provisioning_state phase) and hand it to archinstall
            # through both places it may look: the disk_encryption block and
            # the credentials file.
            _inject_provisioning_encryption_password(arch_configuration, user_credentials)
            creds_path = state_dir / "provisioning-user_credentials.json"
            creds_path.write_text(json.dumps(user_credentials, indent=2) + "\n")
            creds_path.chmod(0o600)

        arch_config_path = state_dir / "archinstall-user_configuration.json"
        arch_config_path.write_text(json.dumps(arch_configuration, indent=2) + "\n")

        ctx = cls(
            config_path=config_path,
            creds_path=creds_path,
            full_name=_read_text(os.environ.get("OMARCHY_INSTALL_FULL_NAME_FILE")),
            email=_read_text(os.environ.get("OMARCHY_INSTALL_EMAIL_FILE")),
            encrypt=_read_text(os.environ.get("OMARCHY_INSTALL_ENCRYPT_FILE")).lower() in ("true", "yes", "1"),
            authorized_keys_path=_optional_path(os.environ.get("OMARCHY_INSTALL_AUTHORIZED_KEYS_FILE")),
            tailscale_authkey_path=_optional_path(os.environ.get("OMARCHY_INSTALL_TAILSCALE_AUTHKEY_FILE")),
            user_configuration=user_configuration,
            user_credentials=user_credentials,
            arch_config_path=arch_config_path,
            omarchy_install=omarchy_install,
            defer_provisioning=defer_provisioning,
            state_dir=state_dir,
        )
        disk_config = user_configuration.get("disk_config", {})
        target_mount = omarchy_install.get("target_mount") or disk_config.get("mountpoint")
        if target_mount:
            ctx.target = Path(target_mount)
        return ctx

    @property
    def username(self) -> str:
        users = self.user_credentials.get("users") or []
        if users:
            return users[0]["username"]
        if self.defer_provisioning:
            return ""
        raise RuntimeError("user_credentials.json contains no users")

    @property
    def mode(self) -> str:
        if mode := self.omarchy_install.get("mode"):
            return mode
        cfg_type = self.user_configuration.get("disk_config", {}).get("config_type")
        return "protected" if cfg_type == "pre_mounted_config" else "full_disk"

    @property
    def is_protected(self) -> bool:
        return self.mode == "protected"


def _strip_account_fields(arch_configuration: dict) -> None:
    """Remove every field archinstall reads to create users or set a root
    password, so it cannot ship a hidden provisioning account.
    Encryption material lives elsewhere (disk_config.disk_encryption) and is
    untouched."""
    for key in ("!users", "!root-password", "root_enc_password", "users"):
        arch_configuration.pop(key, None)

    auth = arch_configuration.get("auth_config")
    if isinstance(auth, dict):
        for key in ("users", "root_enc_password"):
            auth.pop(key, None)


def _inject_provisioning_encryption_password(arch_configuration: dict, user_credentials: dict) -> None:
    """Ensure an encrypted deferred-provisioning install has a LUKS passphrase archinstall can
    use. Reuse one the input already carries (an autoinstall rig may supply
    its own); otherwise generate a throwaway. Mutates the disk_encryption
    block in place — arch_configuration shares it with user_configuration, so
    the stage_provisioning_state phase can read the effective passphrase back."""
    disk_encryption = (arch_configuration.get("disk_config") or {}).get("disk_encryption")
    if disk_encryption is None:
        return

    password = disk_encryption.get("encryption_password") or user_credentials.get("encryption_password")
    if not password:
        password = secrets.token_urlsafe(24)

    disk_encryption["encryption_password"] = password
    user_credentials["encryption_password"] = password


def _default_omarchy_install(user_configuration: dict) -> dict[str, Any]:
    disk_config = user_configuration.get("disk_config", {})
    mode = "protected" if disk_config.get("config_type") == "pre_mounted_config" else "full_disk"
    return {
        "mode": mode,
        "target_mount": disk_config.get("mountpoint") or "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": _LIMINE_EFI_BINARY,
            "enable_fallback": mode == "full_disk",
        },
        "storage": {},
    }


def _optional_path(path: str | None) -> Path | None:
    """A path the caller always passes but that need not exist. The live ISO
    passes --authorized-keys-file on every install; only autoinstall drives put
    a file there."""
    if not path:
        return None
    p = Path(path)
    return p if p.exists() else None


def _read_text(path: str | None) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text().strip()
