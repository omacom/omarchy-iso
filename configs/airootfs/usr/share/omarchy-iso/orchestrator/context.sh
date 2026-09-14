# shellcheck shell=bash
# Install context: parsed configurator output, invocation paths, and the
# per-run state that lives across phases. Port of context.py; each phase
# unit's run-phase rebuilds the CTX_* globals in its own process from the
# persisted env files, and the cross-phase mutable state below travels via
# run-phase's library-state handoff.

CTX_CREDS_PATH='' CTX_FULL_NAME='' CTX_EMAIL='' CTX_ENCRYPT=false
CTX_AUTHORIZED_KEYS_PATH='' CTX_TAILSCALE_AUTHKEY_PATH=''
CTX_USER_CONFIGURATION='{}' CTX_USER_CREDENTIALS='{}' CTX_ARCH_CONFIG_PATH='' CTX_OMARCHY_INSTALL='{}'
CTX_DEFER_PROVISIONING=false
CTX_USERNAME='' CTX_MODE='' CTX_IS_PROTECTED=false
# The path defaults live in context.env, which doubles as an EnvironmentFile=
# for systemd units (see its header for the format rules + runtime layer).
# shellcheck source=configs/airootfs/usr/share/omarchy-iso/orchestrator/context.env
source "${BASH_SOURCE[0]%/*}/context.env"
# Mutable per-run state shared across phases (ctx.state in Python).
CTX_OMARCHY_START_TIME='' CTX_OMARCHY_START_EPOCH=''
CTX_FINALIZER_HEADER_WRITTEN=false

config_error() {
  error "Configuration error: $*"
  exit 2
}

# The static .mount units (mnt-*.mount) hard-code their Where= under /mnt,
# which pins the install target: every mount into the target goes through
# systemd, so fail loudly if CTX_TARGET ever diverges from the units' paths.
require_target_is_mnt() {
  [[ $CTX_TARGET == /mnt ]] ||
    fail "the shipped .mount units pin the install target at /mnt but the target is $CTX_TARGET"
}

# InstallContext.from_env()
ctx_from_env() {
  local config_str=${OMARCHY_INSTALL_CONFIG:-} creds_str=${OMARCHY_INSTALL_CREDS:-}
  [[ -n $config_str && -n $creds_str ]] || config_error 'OMARCHY_INSTALL_CONFIG and OMARCHY_INSTALL_CREDS must be set'

  CTX_CREDS_PATH=$creds_str
  [[ -f $config_str ]] || config_error "configuration file missing: $config_str"
  CTX_USER_CONFIGURATION=$(jq -c . "$config_str") || config_error "invalid JSON in $config_str"

  CTX_OMARCHY_INSTALL=$(jq -c '.omarchy_install // empty' <<<"$CTX_USER_CONFIGURATION")
  [[ -n $CTX_OMARCHY_INSTALL ]] || CTX_OMARCHY_INSTALL=$(ctx_default_omarchy_install)

  # Deferred provisioning: the whole system installs but user creation is
  # deferred to first boot. Selected by the configurator
  # (omarchy_install.defer_provisioning) or by a `defer-provisioning` marker
  # file on an autoinstall drive, which also replaces the
  # user_credentials.json requirement.
  local marker
  marker=$(optional_path "${OMARCHY_INSTALL_DEFER_PROVISIONING_FILE:-}")
  CTX_DEFER_PROVISIONING=false
  if [[ $(jq -r '.defer_provisioning // false' <<<"$CTX_OMARCHY_INSTALL") == true || -n $marker ]]; then
    CTX_DEFER_PROVISIONING=true
  fi
  CTX_OMARCHY_INSTALL=$(jq -c --argjson d "$CTX_DEFER_PROVISIONING" '.defer_provisioning = $d' <<<"$CTX_OMARCHY_INSTALL")

  if [[ -f $creds_str ]]; then
    CTX_USER_CREDENTIALS=$(jq -c . "$creds_str") || config_error "invalid JSON in $creds_str"
  elif [[ $CTX_DEFER_PROVISIONING == true ]]; then
    CTX_USER_CREDENTIALS='{"users": []}'
  else
    config_error "credentials file missing: $creds_str"
  fi

  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    # Deferred provisioning promises no account until first boot. A supplied
    # credentials file (a rig handing over its LUKS passphrase) must not
    # smuggle in users or a root password.
    CTX_USER_CREDENTIALS=$(jq -c '{users: []} + (if (.encryption_password // "") != "" then {encryption_password} else {} end)' <<<"$CTX_USER_CREDENTIALS")
  fi

  local arch_configuration
  arch_configuration=$(jq -c 'del(.omarchy_install)' <<<"$CTX_USER_CONFIGURATION")
  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    # The userless invariant covers the archinstall-format config too: a
    # combined/legacy config could carry account authentication that the
    # installer would still act on (users, a root password). Strip every such
    # field so no account is created before first boot.
    arch_configuration=$(ctx_strip_account_fields "$arch_configuration")
  fi

  CTX_STATE_DIR=${OMARCHY_INSTALL_STATE_DIR:-/run/omarchy-install}
  mkdir -p "$CTX_STATE_DIR"

  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    # Encrypted deferred-provisioning installs have no user password to protect
    # LUKS with. Generate a throwaway passphrase (staged for first-boot re-key
    # by the stage_provisioning_state phase) and hand it to the installer
    # through both places it may look: the disk_encryption block and the
    # credentials file.
    if [[ $(jq -r '.disk_config.disk_encryption // empty | type' <<<"$arch_configuration") == object ]]; then
      local password
      password=$(jq -r '.disk_config.disk_encryption.encryption_password // empty' <<<"$arch_configuration")
      [[ -n $password ]] || password=$(jq -r '.encryption_password // empty' <<<"$CTX_USER_CREDENTIALS")
      # Before generating, reuse what an earlier parse of this install
      # persisted below: ctx_from_env must be deterministic across processes
      # (run-phase rebuilds the context in every phase unit), and a freshly
      # generated passphrase here would not be the one the disk was
      # encrypted with.
      [[ -n $password ]] ||
        password=$(jq -r '.encryption_password // empty' "$CTX_STATE_DIR/provisioning-user_credentials.json" 2>/dev/null)
      [[ -n $password ]] || password=$(ctx_generate_passphrase)
      arch_configuration=$(jq -c --arg p "$password" '.disk_config.disk_encryption.encryption_password = $p' <<<"$arch_configuration")
      # arch_configuration shares the block with user_configuration in Python;
      # keep both views in step so stage_provisioning_state reads it back.
      CTX_USER_CONFIGURATION=$(jq -c --arg p "$password" '.disk_config.disk_encryption.encryption_password = $p' <<<"$CTX_USER_CONFIGURATION")
      CTX_USER_CREDENTIALS=$(jq -c --arg p "$password" '.encryption_password = $p' <<<"$CTX_USER_CREDENTIALS")
    fi
    CTX_CREDS_PATH="$CTX_STATE_DIR/provisioning-user_credentials.json"
    (umask 077 && jq . <<<"$CTX_USER_CREDENTIALS" >"$CTX_CREDS_PATH")
    chmod 0600 "$CTX_CREDS_PATH"
  fi

  CTX_ARCH_CONFIG_PATH="$CTX_STATE_DIR/archinstall-user_configuration.json"
  jq . <<<"$arch_configuration" >"$CTX_ARCH_CONFIG_PATH"

  CTX_FULL_NAME=$(ctx_read_env_file "${OMARCHY_INSTALL_FULL_NAME_FILE:-}")
  CTX_EMAIL=$(ctx_read_env_file "${OMARCHY_INSTALL_EMAIL_FILE:-}")
  case $(ctx_read_env_file "${OMARCHY_INSTALL_ENCRYPT_FILE:-}" | tr '[:upper:]' '[:lower:]') in
    true|yes|1) CTX_ENCRYPT=true ;;
    *) CTX_ENCRYPT=false ;;
  esac
  CTX_AUTHORIZED_KEYS_PATH=$(optional_path "${OMARCHY_INSTALL_AUTHORIZED_KEYS_FILE:-}")
  CTX_TAILSCALE_AUTHKEY_PATH=$(optional_path "${OMARCHY_INSTALL_TAILSCALE_AUTHKEY_FILE:-}")

  local target_mount
  target_mount=$(jq -r '.target_mount // empty' <<<"$CTX_OMARCHY_INSTALL")
  [[ -n $target_mount ]] || target_mount=$(jq -r '.disk_config.mountpoint // empty' <<<"$CTX_USER_CONFIGURATION")
  [[ -n $target_mount ]] && CTX_TARGET=$target_mount

  CTX_USERNAME=$(jq -r '.users[0].username // empty' <<<"$CTX_USER_CREDENTIALS")
  if [[ -z $CTX_USERNAME && $CTX_DEFER_PROVISIONING != true ]]; then
    config_error 'user_credentials.json contains no users'
  fi

  CTX_MODE=$(jq -r '.mode // empty' <<<"$CTX_OMARCHY_INSTALL")
  if [[ -z $CTX_MODE ]]; then
    if [[ $(jq -r '.disk_config.config_type // empty' <<<"$CTX_USER_CONFIGURATION") == pre_mounted_config ]]; then
      CTX_MODE=protected
    else
      CTX_MODE=full_disk
    fi
  fi
  CTX_IS_PROTECTED=false
  [[ $CTX_MODE == protected ]] && CTX_IS_PROTECTED=true

  ctx_write_runtime_env
  return 0
}

# The resolved paths, for systemd units: context.env carries the defaults,
# and a unit that needs the live values layers this file over it
# (EnvironmentFile=-/run/omarchy-install/context.env -- later files win).
# The same four keys as the defaults file, nothing else: the rest of the
# context is process state, not configuration.
ctx_write_runtime_env() {
  cat >"$CTX_STATE_DIR/context.env" <<EOF
CTX_TARGET='$CTX_TARGET'
CTX_OMARCHY_PATH='$CTX_OMARCHY_PATH'
CTX_STATE_DIR='$CTX_STATE_DIR'
CTX_LOG_PATH='$CTX_LOG_PATH'
EOF

  # The raw OMARCHY_INSTALL_* inputs, for the systemd phase units: a phase
  # runs in its own process (run-phase), and ctx_from_env is deterministic
  # given these, so re-running it there rebuilds this exact context. Same
  # dual format as context.env — units take it as an EnvironmentFile=, bash
  # sources it.
  local var
  {
    for var in $(compgen -v OMARCHY_INSTALL_); do
      printf "%s='%s'\n" "$var" "${!var}"
    done
  } >"$CTX_STATE_DIR/install.env"
}

# _strip_account_fields(): encryption material lives in
# disk_config.disk_encryption and is untouched.
ctx_strip_account_fields() {
  jq -c 'del(."!users", ."!root-password", .root_enc_password, .users)
         | if (.auth_config | type) == "object" then .auth_config |= del(.users, .root_enc_password) else . end' <<<"$1"
}

# secrets.token_urlsafe(24): 32 URL-safe characters.
ctx_generate_passphrase() {
  tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 32
}

# _default_omarchy_install()
ctx_default_omarchy_install() {
  local mode=full_disk
  [[ $(jq -r '.disk_config.config_type // empty' <<<"$CTX_USER_CONFIGURATION") == pre_mounted_config ]] && mode=protected
  jq -c -n --arg mode "$mode" --arg target "$(jq -r '.disk_config.mountpoint // "/mnt"' <<<"$CTX_USER_CONFIGURATION")" '{
    mode: $mode, target_mount: (if $target == "" then "/mnt" else $target end),
    boot: {esp_mount: "/boot", esp_path: "/EFI/limine", efi_binary: "limine_x64.efi", enable_fallback: ($mode == "full_disk")},
    storage: {}}'
}

# _read_text(): stripped content of an optional file.
ctx_read_env_file() {
  [[ -n ${1:-} && -f $1 ]] || return 0
  local text
  text=$(<"$1")
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

# Accessors over the Omarchy-specific part of the configurator JSON.
omarchy_install_get() {
  jq -r "$1 // empty" <<<"$CTX_OMARCHY_INSTALL"
}

user_configuration_get() {
  jq -r "$1 // empty" <<<"$CTX_USER_CONFIGURATION"
}
