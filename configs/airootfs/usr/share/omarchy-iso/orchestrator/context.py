"""Install context: parsed configurator output, invocation paths, and a
mutable `state` dict for objects that live across phases (e.g., the
archinstall config handler and mirror list handler)."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class InstallContext:
    config_path: Path
    creds_path: Path
    full_name: str
    email: str
    encrypt: bool
    ssh_keys_path: Path | None

    user_configuration: dict
    user_credentials: dict
    arch_config_path: Path
    omarchy_install: dict[str, Any]

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

        arch_configuration = dict(user_configuration)
        arch_configuration.pop("omarchy_install", None)
        state_dir = Path(os.environ.get("OMARCHY_INSTALL_STATE_DIR", "/run/omarchy-install"))
        state_dir.mkdir(parents=True, exist_ok=True)
        arch_config_path = state_dir / "archinstall-user_configuration.json"
        arch_config_path.write_text(json.dumps(arch_configuration, indent=2) + "\n")

        ctx = cls(
            config_path=config_path,
            creds_path=creds_path,
            full_name=_read_text(os.environ.get("OMARCHY_INSTALL_FULL_NAME_FILE")),
            email=_read_text(os.environ.get("OMARCHY_INSTALL_EMAIL_FILE")),
            encrypt=_read_text(os.environ.get("OMARCHY_INSTALL_ENCRYPT_FILE")).lower() in ("true", "yes", "1"),
            ssh_keys_path=_optional_path(os.environ.get("OMARCHY_INSTALL_SSH_KEYS_FILE")),
            user_configuration=user_configuration,
            user_credentials=json.loads(creds_path.read_text()),
            arch_config_path=arch_config_path,
            omarchy_install=omarchy_install,
            state_dir=state_dir,
        )
        disk_config = user_configuration.get("disk_config", {})
        target_mount = omarchy_install.get("target_mount") or disk_config.get("mountpoint")
        if target_mount:
            ctx.target = Path(target_mount)
        return ctx

    @property
    def username(self) -> str:
        return self.user_credentials["users"][0]["username"]

    @property
    def mode(self) -> str:
        if mode := self.omarchy_install.get("mode"):
            return mode
        cfg_type = self.user_configuration.get("disk_config", {}).get("config_type")
        return "protected" if cfg_type == "pre_mounted_config" else "full_disk"

    @property
    def is_protected(self) -> bool:
        return self.mode == "protected"


def _default_omarchy_install(user_configuration: dict) -> dict[str, Any]:
    disk_config = user_configuration.get("disk_config", {})
    mode = "protected" if disk_config.get("config_type") == "pre_mounted_config" else "full_disk"
    return {
        "mode": mode,
        "target_mount": disk_config.get("mountpoint") or "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": "limine_x64.efi",
            "enable_fallback": mode == "full_disk",
        },
        "storage": {},
    }


def _optional_path(path: str | None) -> Path | None:
    """A path the caller always passes but that need not exist. The live ISO
    passes --ssh-keys-file on every install; only autoinstall drives put a file
    there."""
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
