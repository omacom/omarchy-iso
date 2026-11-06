#!/bin/bash
# The runner's Docker facility grants loop devices to this build environment.
# Podman runs the actual ISO builder inside it, with private disposable storage.
set -euo pipefail

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
owner="$(id -u):$(id -g)"
status=0
if docker run --rm --privileged --cgroupns=host \
  -v "$root:$root" -w "$root" \
  -e NO_BOOT_OFFER -e OMARCHY_ISO_REF -e OMARCHY_MIRROR \
  -e OMARCHY_ARCH -e OMARCHY_INSTALL_DEBUG \
  -e OMARCHY_RUNTIME_PACKAGE -e OMARCHY_SETTINGS_PACKAGE \
  docker.io/library/ubuntu:26.04 bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends podman crun sudo git ca-certificates
    git config --global --add safe.directory "$PWD"
    git config --global --add safe.directory "$PWD/archiso"
    install -d /etc/containers/containers.conf.d
    printf "%s\n" "[containers]" "keyring=false" "cgroups=\"disabled\"" "netns=\"host\"" "default_sysctls=[]" "[engine]" "cgroup_manager=\"cgroupfs\"" "no_pivot_root=true" > /etc/containers/containers.conf.d/omarchy-iso-ci.conf
    printf "[storage]\ndriver=\"vfs\"\ngraphroot=\"/var/lib/omarchy-iso-podman/storage\"\nrunroot=\"/run/omarchy-iso-podman\"\n" >/etc/containers/storage.conf
    ./bin/omarchy-iso-make "$@"
  ' bash "$@"; then
  status=0
else
  status=$?
fi

# The bootstrap runs as root; leave its artifacts usable by the runner user,
# also when the build failed and only diagnostics were produced.
if [[ -d $root/release ]]; then
  if ! sudo chown -R "$owner" "$root/release"; then
    if ((status == 0)); then
      status=1
    fi
  fi
fi
exit "$status"
