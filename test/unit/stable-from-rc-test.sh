#!/bin/bash
#
# A final release's ISO can be built from rc before rc is promoted to stable
# and still install onto stable: --stable-from-rc. The build channel
# (OMARCHY_MIRROR) picks the mirrors the ISO is built from; the install channel
# (OMARCHY_INSTALL_CHANNEL) is what build-iso.sh writes to /root/omarchy_mirror,
# which the installed runtime turns into its pacman.conf. These run the real
# omarchy-iso-make and omarchy-iso-release from a sandbox with docker, git,
# curl and the signing and upload steps stubbed out.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Both scripts find the repo from their own path, so copying them into a
# sandbox points their release/ directory there.
sandbox="$work/repo"
stubs="$work/stubs"
mkdir -p "$sandbox/bin" "$sandbox/configs" "$sandbox/release" "$stubs"
cp "$ROOT/bin/omarchy-iso-make" "$ROOT/bin/omarchy-iso-release" "$sandbox/bin/"
: >"$sandbox/configs/profiledef.sh"

# docker run: record the environment it was given and leave an ISO behind, as
# the real build does in the mounted release directory.
cat >"$stubs/docker" <<'STUB'
#!/bin/bash
[[ $1 == run ]] || exit 0
printf '%s\n' "$@" | grep -E '^OMARCHY_(ISO_REF|MIRROR|INSTALL_CHANNEL)=' >"$DOCKER_ENV"
printf 'not really an iso\n' >"$SANDBOX/release/omarchy-2099.01.01-x86_64.iso"
STUB

# git: the submodule update. sudo: the host package cache purge, which a
# release build runs and this test must never carry out.
for tool in git sudo; do
  printf '#!/bin/bash\nexit 0\n' >"$stubs/$tool"
done

# curl serves a package database listing the packages in $RC_PACKAGES.
cat >"$stubs/curl" <<'STUB'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
  [[ $1 == -o ]] && { out=$2; shift; }
  shift
done
[[ -n ${CURL_FAIL:-} ]] && exit 22
dir=$(mktemp -d)
for package in $RC_PACKAGES; do
  mkdir -p "$dir/$package"
  : >"$dir/$package/desc"
done
# Entries named as repo-add names them (omarchy-4.5.0-1/desc), with no ./
(cd "$dir" && tar --zstd -cf "$out" -- *)
rm -rf "$dir"
STUB

cat >"$stubs/omarchy-iso-sign" <<'STUB'
#!/bin/bash
printf 'signature\n' >"$1.sig"
STUB

cat >"$stubs/omarchy-iso-upload" <<'STUB'
#!/bin/bash
printf '%s\n' "${1##*/}" >>"$UPLOADS"
STUB

chmod +x "$stubs"/*

# omarchy-iso-make keeps its package cache under $HOME, which CI's test user
# can't write (it runs with root's HOME).
export HOME="$work/home"
export SANDBOX="$sandbox" DOCKER_ENV="$work/docker-env" UPLOADS="$work/uploads"
export PATH="$sandbox/bin:$stubs:$PATH"

make_env() { # make_env <omarchy-iso-make args...>: the channel environment it builds with
  rm -f "$DOCKER_ENV" "$sandbox/release"/*.iso
  omarchy-iso-make --keep-pkg-cache --no-boot-offer "$@" >/dev/null 2>"$work/make-err" || return
  paste -sd' ' "$DOCKER_ENV"
}

# --- omarchy-iso-make -----------------------------------------------------------
env=$(make_env --stable-from-rc) || fail "--stable-from-rc builds" "$(cat "$work/make-err")"
[[ $env == "OMARCHY_ISO_REF=release OMARCHY_MIRROR=rc OMARCHY_INSTALL_CHANNEL=stable" ]] ||
  fail "--stable-from-rc builds from rc and installs onto stable" "$env"
[[ -f $sandbox/release/omarchy-2099.01.01-x86_64-release.iso ]] ||
  fail "--stable-from-rc names its ISO for the release ref" "$(ls "$sandbox/release")"
pass "--stable-from-rc builds from rc and installs onto stable"

for case in "--rc:rc:rc" "--edge:edge:edge" ":quattro:stable"; do
  flag=${case%%:*} rest=${case#*:}
  ref=${rest%%:*} channel=${rest#*:}
  # shellcheck disable=SC2086 # an empty flag is no argument at all
  env=$(make_env $flag) || fail "${flag:-the default build} builds" "$(cat "$work/make-err")"
  [[ $env == "OMARCHY_ISO_REF=$ref OMARCHY_MIRROR=$channel OMARCHY_INSTALL_CHANNEL=$channel" ]] ||
    fail "${flag:-the default build} installs the channel it builds from" "$env"
done
pass "every other build installs the channel it builds from"

env=$(OMARCHY_INSTALL_CHANNEL=stable make_env --edge) || fail "an install channel in the environment is ignored" "$(cat "$work/make-err")"
[[ $env == *"OMARCHY_INSTALL_CHANNEL=edge" ]] || fail "an install channel in the environment is ignored" "$env"
pass "only --stable-from-rc sets the install channel"

mkdir -p "$work/omarchy" "$work/pkgs" "$work/bundle"
: >"$work/bundle/SHA256SUMS"
printf 'ssh-ed25519 AAAA test\n' >"$work/key.pub"
# A channel flag after --stable-from-rc moves the build off rc. One before it is
# overridden, as any later channel flag overrides an earlier one.
for flag in --edge --dev --rc --quattro; do
  if make_env --stable-from-rc "$flag" >/dev/null; then
    fail "--stable-from-rc refuses $flag after it"
  fi
  grep -Fq "can't be combined" "$work/make-err" || fail "--stable-from-rc says why it refuses $flag" "$(cat "$work/make-err")"
done
# These put other packages, or a dev key, into the build and stay set whatever
# comes after them, so they're refused on either side.
for flags in "--local-source $work/omarchy $work/pkgs" \
  "--arch aarch64 --package-dir $work/bundle" "--arch aarch64 --dev-ssh $work/key.pub"; do
  for order in "--stable-from-rc $flags" "$flags --stable-from-rc"; do
    # shellcheck disable=SC2086 # each case is several arguments
    if make_env $order >/dev/null; then
      fail "--stable-from-rc refuses: $order"
    fi
    grep -Fq "can't be combined" "$work/make-err" || fail "--stable-from-rc says why it refuses: $order" "$(cat "$work/make-err")"
  done
done
pass "--stable-from-rc refuses a flag that changes what goes into the build, in either order"

# --- build-iso.sh ---------------------------------------------------------------
# The builder holds the line too, for anything that runs it without the make
# script: an ISO may install only its own channel, or stable from rc.
check=$(sed -n '/^OMARCHY_INSTALL_CHANNEL=/,/^fi$/p' "$ROOT/builder/build-iso.sh")
[[ -n $check ]] || fail "build-iso.sh checks the install channel"
builder_accepts() { # builder_accepts <build channel> <install channel>
  (OMARCHY_MIRROR=$1 OMARCHY_INSTALL_CHANNEL=$2 eval "$check") 2>/dev/null
}
for pair in "rc stable" "rc rc" "stable stable" "edge edge"; do
  # shellcheck disable=SC2086
  builder_accepts $pair || fail "build-iso.sh accepts $pair"
done
for pair in "edge stable" "stable rc" "rc edge" "edge rc"; do
  # shellcheck disable=SC2086
  if builder_accepts $pair; then
    fail "build-iso.sh refuses $pair"
  fi
done
installed=$(unset OMARCHY_INSTALL_CHANNEL; OMARCHY_MIRROR=edge; eval "$check"; echo "$OMARCHY_INSTALL_CHANNEL")
[[ $installed == edge ]] || fail "build-iso.sh installs the build channel when none is named" "$installed"
grep -Fq 'echo "$OMARCHY_INSTALL_CHANNEL" > "$build_cache_dir/airootfs/root/omarchy_mirror"' "$ROOT/builder/build-iso.sh" ||
  fail "the ISO tells the installer the install channel, not the build channel"
grep -Fq -- '-e "OMARCHY_INSTALL_CHANNEL=$OMARCHY_INSTALL_CHANNEL"' "$ROOT/bin/omarchy-iso-make" ||
  fail "omarchy-iso-make passes the install channel into the build container"
pass "build-iso.sh installs the install channel, and only stable from rc"

# --- omarchy-iso-release --------------------------------------------------------
release() { # release <args...>
  rm -f "$sandbox/release"/*
  : >"$UPLOADS"
  omarchy-iso-release "$@" >/dev/null 2>"$work/release-err"
}

RC_PACKAGES="omarchy-4.5.0-1 omarchy-settings-4.5.0-1" release --stable-from-rc 4.5.0 ||
  fail "a final release builds from rc once rc serves it" "$(cat "$work/release-err")"
[[ $(cat "$UPLOADS") == omarchy-4.5.0.iso ]] ||
  fail "a final release built from rc keeps the final release's name" "$(cat "$UPLOADS")"
[[ $(paste -sd' ' "$DOCKER_ENV") == *"OMARCHY_INSTALL_CHANNEL=stable" ]] ||
  fail "omarchy-iso-release --stable-from-rc installs onto stable" "$(cat "$DOCKER_ENV")"
pass "omarchy-iso-release --stable-from-rc releases omarchy-4.5.0.iso, installing onto stable"

for packages in "omarchy-4.5.0rc3-1 omarchy-settings-4.5.0rc3-1" "omarchy-4.5.0-1 omarchy-settings-4.5.0rc3-1" "omarchy-4.5.0-1"; do
  rm -f "$DOCKER_ENV"
  if RC_PACKAGES=$packages release --stable-from-rc 4.5.0; then
    fail "a final release is refused while rc serves $packages"
  fi
  [[ ! -f $DOCKER_ENV ]] || fail "nothing is built while rc serves $packages"
  grep -Fq "doesn't serve" "$work/release-err" || fail "the refusal says rc doesn't serve the release" "$(cat "$work/release-err")"
done
pass "a final release isn't built until rc serves its omarchy and omarchy-settings"

if CURL_FAIL=1 release --stable-from-rc 4.5.0; then
  fail "a final release is refused when rc's database can't be read"
fi
pass "a final release is refused when rc's database can't be read"

for args in "--stable-from-rc 4.5.0rc4" "--stable-from-rc --rc 4.5.0" "--rc --stable-from-rc 4.5.0"; do
  # shellcheck disable=SC2086
  if RC_PACKAGES="omarchy-4.5.0-1 omarchy-settings-4.5.0-1" release $args; then
    fail "omarchy-iso-release refuses $args"
  fi
done
pass "--stable-from-rc is only for a final release"
