"""Omarchy install orchestrator.

Single tool that owns the full install phase ordering, with archinstall used as
a library subsystem (not as the top-level installer).

The live-ISO wrapper consumes CLI args and passes configuration paths via
OMARCHY_INSTALL_* environment variables before Python starts. This keeps
archinstall's import-time CLI parsing from seeing Omarchy-specific flags.
"""

from __future__ import annotations

import signal
import sys
from .context import InstallContext
from .phases import PhaseError, run
from .ui import error, info


def _raise_on_sigterm(signum, frame):
    # The dashboard stops an install by SIGTERMing this process group and
    # escalates to SIGKILL only after a grace period. Python's default
    # disposition would exit without unwinding, skipping main()'s
    # finally-cleanups and the phases' own except paths (e.g. killing the
    # detached keyring init, which start_new_session puts outside the group
    # the dashboard kills); raising turns the stop into a normal unwind.
    raise SystemExit(128 + signum)


def build_phases(ctx: InstallContext):
    """Phase order. Each entry is (display name, callable taking InstallContext).

    The ordering is the whole point of this orchestrator: package-install
    hooks (limine-mkinitcpio-hook, in particular) and useradd happen at
    points where their prerequisites are guaranteed to be in place.

    Full-disk and protected installs use the same phase sequence. The
    configurator only changes the JSON input: full-disk asks archinstall to
    create/mount the layout, while protected provides an already-mounted target
    and the partition details Omarchy needs for boot/fstab generation.
    """
    from .phases_impl import (
        prepare_live,
        prepare_install_target,
        arch_install_system,
        configure_hibernation,
        run_system_finalizer,
        stage_provisioning_state,
        finalize_limine_boot,
        run_chroot_finalizer,
        configure_dns_resolver,
        configure_login,
        configure_ssh_access,
        configure_tailscale,
        validate_boot,
        create_factory_snapshot,
    )

    return [
        ("Preparing live environment", prepare_live),
        ("Preparing install target",   prepare_install_target),
        ("Installing Arch + Omarchy",  arch_install_system),
        ("Configuring hibernation",    configure_hibernation),
        ("Configuring system",         run_system_finalizer),
        # Before finalize_limine_boot: the deferred-provisioning cryptkey drop-in and keyfile
        # must be in place for the final UKI build.
        ("Staging provisioning",          stage_provisioning_state),
        ("Finalizing Limine boot",     finalize_limine_boot),
        ("Finalizing user",            run_chroot_finalizer),
        ("Configuring login",          configure_login),
        ("Configuring SSH access",     configure_ssh_access),
        ("Configuring Tailscale",      configure_tailscale),
        ("Configuring DNS resolver",   configure_dns_resolver),
        ("Validating boot setup",      validate_boot),
        ("Creating factory snapshot",  create_factory_snapshot),
    ]


def main() -> int:
    signal.signal(signal.SIGTERM, _raise_on_sigterm)
    try:
        ctx = InstallContext.from_env()
    except RuntimeError as e:
        error(f"Configuration error: {e}")
        return 2

    who = ctx.username or "deferred provisioning (user created at first boot)"
    info(f"Installing Omarchy for {who} → {ctx.target}")

    from .phases_impl import (
        boost_cpu_governor,
        cleanup_bind_mounts,
        cleanup_protected_state,
        cleanup_target_hook_masks,
        restore_cpu_governors,
    )

    governors = boost_cpu_governor()

    success = False
    try:
        try:
            run(ctx, build_phases(ctx))
            success = True
        except PhaseError:
            error("Installation halted.")
            return 1
        except KeyboardInterrupt:
            error("Installation interrupted.")
            return 130

        info("Installation complete.")
        return 0
    finally:
        restore_cpu_governors(governors)
        cleanup_bind_mounts(ctx)
        cleanup_target_hook_masks(ctx)
        if not success:
            cleanup_protected_state(ctx)


if __name__ == "__main__":
    sys.exit(main())
