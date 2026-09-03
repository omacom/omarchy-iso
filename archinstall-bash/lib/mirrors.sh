# shellcheck shell=bash
# Port of Installer.set_mirrors() and the config rendering in
# lib/models/mirrors.py. The live mirror-status download and speed sort of
# lib/mirror/mirror_handler.py are not ported: regions are served from the
# live system's /etc/pacman.d/mirrorlist (what upstream does in --offline mode).

MIRRORLIST=/etc/pacman.d/mirrorlist

# MirrorConfiguration.custom_servers_config()
mirrors_custom_servers_config() {
  ((${#CFG_MIRROR_CUSTOM_SERVERS[@]})) || return 0
  printf '## Custom Servers\n'
  local s
  for s in "${CFG_MIRROR_CUSTOM_SERVERS[@]}"; do
    printf 'Server = %s\n' "$s"
  done
}

# MirrorConfiguration.regions_config() against the local mirrorlist.
mirrors_regions_config() {
  ((${#CFG_MIRROR_REGIONS[@]})) || return 0
  local region
  for region in "${CFG_MIRROR_REGIONS[@]}"; do
    printf '\n\n## %s\n' "$region"
    awk -v region="$region" '
      /^## / { current = substr($0, 4) }
      current == region && /^#?[[:space:]]*Server[[:space:]]*=/ { sub(/^#[[:space:]]*/, ""); print }
    ' "$MIRRORLIST" 2>/dev/null
  done
}

# MirrorConfiguration.repositories_config()
mirrors_repositories_config() {
  ((${#CFG_MIRROR_CUSTOM_REPOS[@]})) || return 0
  local name url check option
  for entry in "${CFG_MIRROR_CUSTOM_REPOS[@]}"; do
    IFS=$'\x1f' read -r name url check option <<<"$entry"
    printf '\n\n[%s]\nSigLevel = %s %s\nServer = %s\n' "$name" "$check" "$option" "$url"
  done
}

# Installer.set_mirrors(on_target)
installer_set_mirrors() {
  local on_target=${1:-} mirrorlist pacman_conf content
  if [[ $on_target == on_target || $on_target == 1 ]]; then
    debug 'Setting mirrors on target'
    mirrorlist="$INST_TARGET$MIRRORLIST"
    pacman_conf="$INST_TARGET$PACMAN_CONF"
  else
    debug 'Setting mirrors on live system'
    mirrorlist=$MIRRORLIST
    pacman_conf=$PACMAN_CONF
  fi

  content=$(mirrors_repositories_config)
  if [[ -n $content ]]; then
    debug "Pacman config: $content"
    printf '%s\n' "$content" >>"$pacman_conf"
  fi

  content=$(mirrors_regions_config)
  if [[ -n $content ]]; then
    debug "Mirrorlist: $content"
    printf '%s\n' "$content" >"$mirrorlist"
  fi

  content=$(mirrors_custom_servers_config)
  if [[ -n $content ]]; then
    debug "Custom servers: $content"
    local existing=''
    [[ -f $mirrorlist ]] && existing=$(cat "$mirrorlist")
    printf '%s\n\n%s\n' "$content" "$existing" >"$mirrorlist"
  fi
}
