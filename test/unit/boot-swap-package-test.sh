#!/bin/bash
#
# UEFI installs swap the image's Limine stack for omarchy-boot-systemd from the
# offline mirror. The build ships it only with a runtime that can finish the
# swap (omarchy-boot-switch), stops when pacman can't resolve it, ships what a
# local build of it depends on, and a release rehearsal builds it with the
# omarchy it is released in lockstep with.

# shellcheck disable=SC2034 # the variables are read by the builder lines run through eval

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$ROOT/builder/build-iso.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ------------------------------------------------- choosing the swap package
choice=$(sed -n '/^boot_swap_package=""$/,/^fi$/p' "$builder")
[[ -n $choice ]] || fail "the builder has no boot swap choice"
choice=${choice//\/omarchy-source/$work/src}

choose() { # resolvable: yes or no
  local resolvable=$1
  pacman() {
    case " $* " in
      *" -Sp "*) return 0 ;;
      *" -Sw "*) return 0 ;;
      *" --print "*) [[ $resolvable == yes ]] && echo omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst ;;
    esac
  }
  local_packages=(omarchy-settings omarchy)
  LOCAL_OMARCHY_BUILD=1 OMARCHY_ARCH=x86_64 online_pacman_conf=/dev/null offline_mirror_dir=$work/mirror
  required_package_files=(base-1-1-any.pkg.tar.zst)
  eval "$choice"
  echo "${boot_swap_package:-none} ${required_package_files[*]}"
}

mkdir -p "$work/src/bin"
[[ $(choose yes 2>/dev/null) == "none base-1-1-any.pkg.tar.zst" ]] ||
  fail "a runtime without omarchy-boot-switch gets the channel's omarchy-boot-systemd"
touch "$work/src/bin/omarchy-boot-switch"
[[ $(choose yes) == "omarchy-boot-systemd base-1-1-any.pkg.tar.zst omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst" ]] ||
  fail "a runtime with omarchy-boot-switch does not get the channel's omarchy-boot-systemd: $(choose yes)"
if (choose no) >/dev/null 2>&1; then fail "an omarchy-boot-systemd pacman can't resolve is shipped anyway"; fi
echo "ok - the channel's omarchy-boot-systemd ships with a runtime that can finish the swap, resolved"

# ----------------------------------------------- what a local build ships with
shipping=$(sed -n '/^# The boot swap package is never in the image/,/^fi$/p' "$builder")
[[ -n $shipping ]] || fail "the builder does not ship the boot swap package's dependencies"
mkdir -p "$work/pkg" "$work/mirror"
printf 'pkgname = omarchy-boot-systemd\ndepend = systemd\ndepend = systemd-ukify\ndepend = efibootmgr\ndepend = some-new-dependency>=2\n' >"$work/pkg/.PKGINFO"
bsdtar -C "$work/pkg" --zstd -cf "$work/mirror/omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst" .PKGINFO
touch "$work/mirror/omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst.sig"
pacman() { echo "resolved:${*: -4}"; }
boot_swap_package=omarchy-boot-systemd LOCAL_OMARCHY_BUILD=1 local_packages=(omarchy omarchy-boot-systemd)
offline_mirror_dir=$work/mirror online_pacman_conf=/dev/null installable_files=base-1-1-any.pkg.tar.zst
eval "$shipping"
[[ $installable_files == $'base-1-1-any.pkg.tar.zst\nomarchy-boot-systemd-1-1-x86_64.pkg.tar.zst\nresolved:systemd systemd-ukify efibootmgr some-new-dependency>=2' ]] ||
  fail "a local omarchy-boot-systemd does not ship with what it depends on: $installable_files"
unset -f pacman
echo "ok - a local omarchy-boot-systemd ships with every dependency it was built with"

# ------------------------------------------------------- the release rehearsal
mkdir -p "$work/repo/bin" "$work/repo/configs" "$work/repo/release" "$work/stubs" "$work/home" "$work/omarchy" "$work/pkgs"
cp "$ROOT/bin/omarchy-iso-make" "$work/repo/bin/"
cp "$ROOT/configs/profiledef.sh" "$work/repo/configs/"
printf '#!/bin/bash\nexit 0\n' >"$work/stubs/git"
cat >"$work/stubs/docker" <<'STUB'
#!/bin/bash
[[ $1 == run ]] && printf '%s\n' "$@" >>"$TEST_DOCKER_LOG"
exit 0
STUB
chmod +x "$work/stubs"/*
export TEST_DOCKER_LOG="$work/docker.log"
rehearsal_packages() {
  : >"$TEST_DOCKER_LOG"
  (cd "$work/repo" && PATH="$work/stubs:$PATH" HOME="$work/home" \
    "$work/repo/bin/omarchy-iso-make" --no-boot-offer --local-source "$work/omarchy" "$work/pkgs" --rehearsal) >/dev/null 2>&1 || true
  sed -n 's/^OMARCHY_LOCAL_PACKAGES=//p' "$TEST_DOCKER_LOG"
}
[[ $(rehearsal_packages) == "omarchy-settings omarchy" ]] || fail "a rehearsal without omarchy-boot-systemd: $(rehearsal_packages)"
mkdir -p "$work/pkgs/pkgbuilds/omarchy-boot-systemd"
[[ $(rehearsal_packages) == "omarchy-settings omarchy omarchy-boot-systemd" ]] ||
  fail "a rehearsal does not build omarchy-boot-systemd with omarchy: $(rehearsal_packages)"
echo "ok - a release rehearsal builds omarchy-boot-systemd with the omarchy it is released with"
