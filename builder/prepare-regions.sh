#!/bin/bash

# Ship every region profile from the bundled runtime, so one ISO serves every
# region. The installer picks a profile from the target's timezone; this only
# stages the profiles and makes their packages downloadable. Repository
# defaults stay in the runtime, not in a second set of ISO-specific templates.
set -euo pipefail

regions_source="$1"
iso_payload="$2"
online_config="$3"

# The source is a checkout's default/regions, or the published settings
# package that ships default/. One predating region profiles ships none; the
# ISO then installs global targets only, exactly as before. Anything else that
# fails here, such as an unreadable package, aborts the build.
regions="$regions_source"
if [[ -f $regions_source ]]; then
  member=usr/share/omarchy/default/regions
  listing=$(bsdtar -tf "$regions_source")
  if grep -q "^$member/" <<<"$listing"; then
    extracted=$(mktemp -d)
    trap 'rm -rf "$extracted"' EXIT
    bsdtar -xf "$regions_source" -C "$extracted" "$member"
    regions="$extracted/$member"
  fi
fi
if [[ ! -d $regions ]]; then
  echo "Runtime ships no region profiles; every install will be global."
  exit 0
fi

cp -a "$regions" "$iso_payload/regions"

for profile in "$regions"/*/; do
  # Only the community repositories are needed to download regional packages.
  # Keep the channel's build mirrors intact; target mirrors are set later by
  # the runtime's own pacman finalizer.
  printf '\n' >> "$online_config"
  cat "$profile/pacman/pacman.conf.append" >> "$online_config"

  # Each keyring package must be signed by a key Arch already trusts. Do not
  # bootstrap trust from an unchecked keyserver response or disable signatures.
  # https://github.com/archlinuxcn/repo#usage
  mapfile -t keyring_packages < <(grep -hv '^#\|^$' "$profile/packages" | grep -- '-keyring$' || true)
  if (( ${#keyring_packages[@]} > 0 )); then
    pacman --config "$online_config" --noconfirm -Sy --needed "${keyring_packages[@]}"
    pacman-key --populate "${keyring_packages[@]%-keyring}"
  fi
done
