#!/bin/bash
#
# The build container installs its own tools (archiso, base-devel, ...) with
# pacman before it builds anything. Those must come from Omarchy's mirror for
# the build's channel, as the ISO's packages do, not from whatever mirror the
# container image came with: on x86_64 that was Arch's public mirror, and a
# stall there failed ISO builds.

# shellcheck disable=SC2034 # online_pacman_conf is read by the builder lines run through eval

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$ROOT/builder/build-iso.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$(sed -n '/^channel_core_server() {$/,/^}$/p' "$builder")"
declare -F channel_core_server >/dev/null || fail "the builder has no channel_core_server"

# Every channel's online configuration, on both architectures, names an Omarchy
# mirror for [core], and that is what the build container is given.
for conf in "$ROOT"/configs/pacman-online-*.conf; do
  server=$(channel_core_server "$conf") || fail "${conf##*/}: no Omarchy mirror for [core]"
  [[ $server == "Server = https://"*"mirror.omarchy.org/"* ]] || fail "${conf##*/}: [core] is $server"
done
echo "ok - every channel's [core] is an Omarchy mirror"

# A configuration whose [core] is somebody else's mirror is refused.
printf '[core]\nServer = https://fastly.mirror.pkgbuild.com/$repo/os/$arch\n' >"$work/foreign.conf"
if channel_core_server "$work/foreign.conf" >/dev/null 2>&1; then fail "a foreign [core] mirror is accepted"; fi
echo "ok - a [core] that is not an Omarchy mirror stops the build"

# On x86_64 the channel's mirror goes first in the container's mirrorlist and
# the image's own mirrors stay after it, the fallback the online configuration
# reaches through its Include. It happens before the first pacman call.
x86=$(sed -n '/^else$/,/^fi$/p' "$builder" | sed -n '1,/pacman --noconfirm -Sy archlinux-keyring/p')
grep -q 'channel_core_server "\$online_pacman_conf"' <<<"$x86" \
  || fail "the x86_64 build container installs its tools from the mirror its image came with"
mirrorlist="$work/mirrorlist"
printf 'Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch\n' >"$mirrorlist"
step=$(sed -n '/channel_core_server "\$online_pacman_conf"/,/\/etc\/pacman.d\/mirrorlist$/p' <<<"$x86" | sed "s|/etc/pacman.d/mirrorlist|$mirrorlist|")
online_pacman_conf="$ROOT/configs/pacman-online-rc.conf"
eval "$step"
servers=$(grep '^Server' "$mirrorlist")
[[ $(head -n1 <<<"$servers") == 'Server = https://rc-mirror.omarchy.org/$repo/os/$arch' ]] \
  || fail "the channel's mirror is not first: $servers"
grep -qF 'fastly.mirror.pkgbuild.com' <<<"$servers" || fail "the image's own mirrors are gone: $servers"
# And a foreign [core] stops it before pacman runs, not with an empty line.
online_pacman_conf="$work/foreign.conf"
if (eval "$step") 2>/dev/null; then fail "the x86_64 step carries on with a foreign [core] mirror"; fi
echo "ok - the x86_64 build container prefers the channel's Omarchy mirror and keeps the rest as fallback"
