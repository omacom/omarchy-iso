# Packages an x86_64 image must carry. The install asks for the T2 Mac set in
# one pacman -S (omarchy install/hardware/apple/fix-t2.sh), and linux-t2 is
# the live kernel on a Mac, so an image that cannot offer one of them must
# fail the build instead of dropping it with a warning.
x86_64_required_packages=(
  linux-t2
  linux-t2-headers
  apple-t2-audio-config
  apple-bcm-firmware-fetcher
  t2fanrd
)

# missing_required_packages <arch>: read the offered package names on stdin
# and print each required one that is not among them.
missing_required_packages() {
  local arch=$1 offered p
  [[ $arch == x86_64 ]] || { cat >/dev/null; return 0; }
  offered=$(cat)
  for p in "${x86_64_required_packages[@]}"; do
    grep -Fxq -- "$p" <<<"$offered" || echo "$p"
  done
}
