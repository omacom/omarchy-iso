# shellcheck shell=bash
# Port of lib/pacman/pacman.py (Pacman) and lib/pacman/config.py (PacmanConfig).

PACMAN_CONF=/etc/pacman.conf
PACMAN_OPTIONAL_REPOS=()

PACMAN_SYNC_UNIT=omarchy-pacman-sync.service

# Pacman.sync(): one -Syy per boot, run by a oneshot unit whose
# RemainAfterExit success is the latch — a blocking start from any process
# after the first is a state query, not a resync.
pacman_sync() {
  systemctl start "$PACMAN_SYNC_UNIT" ||
    die "Could not sync a new package database: $(journalctl --no-pager -o cat -b -u "$PACMAN_SYNC_UNIT" 2>/dev/null | tail -n 3 | tr '\n' ' ')"
}

# Whether pacman's local db in the target records $2 as installed.
target_has_package() {
  local target=$1 name=$2 desc
  for desc in "$target"/var/lib/pacman/local/"$name"-*/desc; do
    [[ -f $desc ]] || continue
    [[ $(sed -n '/^%NAME%$/{n;p;q}' "$desc") == "$name" ]] && return 0
  done
  return 1
}

# Pacman.strap(): pacstrap into the target.
pacman_strap() {
  local -a packages=("$@") missing=()
  ((${#packages[@]})) || return 0
  pacman_sync
  # Only what the target lacks is strapped: on Omarchy the target starts as
  # a full root image and pacstrap must not touch what the image provided;
  # on an empty target everything is missing and this filters nothing.
  local p
  for p in "${packages[@]}"; do
    target_has_package "$INST_TARGET" "$p" || missing+=("$p")
  done
  packages=("${missing[@]}")
  ((${#packages[@]})) || { debug 'all packages already present in target'; return 0; }
  info "Installing packages: ${packages[*]}"
  sys_cmd_peek pacstrap -C "$PACMAN_CONF" -K "$INST_TARGET" "${packages[@]}" --noconfirm --needed ||
    die 'Pacstrap failed. See /var/log/archinstall/install.log or above message for error details'
}

# PacmanConfig.enable()
pacman_config_enable() {
  PACMAN_OPTIONAL_REPOS+=("$@")
}

# PacmanConfig.apply(): uncomment optional repositories in the LIVE
# pacman.conf (pacstrap reads the host configuration).
pacman_config_apply() {
  ((${#PACMAN_OPTIONAL_REPOS[@]})) || return 0
  local -a repos=()
  local r
  for r in "${PACMAN_OPTIONAL_REPOS[@]}"; do
    case $r in
      testing) repos+=(core-testing extra-testing multilib-testing) ;;
      *) repos+=("$r") ;;
    esac
  done
  local tmp
  tmp=$(mktemp)
  awk -v repos="${repos[*]}" '
    BEGIN { n = split(repos, want, " "); for (i = 1; i <= n; i++) w[want[i]] = 1 }
    uncomment_next && /^[[:space:]]*#/ { sub(/^[[:space:]]*#[[:space:]]*/, ""); uncomment_next = 0; print; next }
    { uncomment_next = 0 }
    match($0, /^#[[:space:]]*\[([^]]+)\]/, m) && (m[1] in w) { sub(/^#[[:space:]]*/, ""); uncomment_next = 1 }
    { print }
  ' "$PACMAN_CONF" >"$tmp" && cat "$tmp" >"$PACMAN_CONF"
  rm -f "$tmp"
}

# PacmanConfig.persist(): the live pacman.conf becomes the target's.
pacman_config_persist() {
  cp -p "$PACMAN_CONF" "$INST_TARGET$PACMAN_CONF"
}

# PacmanConfig.configure(): ParallelDownloads / Color on the target.
pacman_config_configure() {
  local parallel=$1 color=$2 conf="$INST_TARGET$PACMAN_CONF"
  [[ -f $conf ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v parallel="$parallel" -v color="$color" '
    /^#?[[:space:]]*ParallelDownloads/ { print "ParallelDownloads = " parallel; next }
    /^#?[[:space:]]*Color[[:space:]]*$/ { print (color == "true" ? "Color" : "#Color"); next }
    { print }
  ' "$conf" >"$tmp" && cat "$tmp" >"$conf"
  rm -f "$tmp"
}
