#!/usr/bin/env bash
# InstallContext.from_env(): deferred-provisioning plumbing (marker file,
# credential-less input, throwaway LUKS passphrase injection).
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/orchestrator-harness.sh"

dir="$TMP/ctx"
write_config() { mkdir -p "$dir"; printf '%s' "$1" >"$dir/user_configuration.json"; }
write_creds() { printf '%s' "$1" >"$dir/user_credentials.json"; }
base_config() { # [defer true|false] [disk_encryption json]
  local defer=${1:-} enc=${2:-}
  jq -n --arg defer "$defer" --argjson enc "${enc:-null}" '
    {disk_config: {config_type: "default_layout"}, omarchy_install: {mode: "full_disk", target_mount: "/mnt"}}
    | if $defer != "" then .omarchy_install.defer_provisioning = ($defer == "true") else . end
    | if $enc != null then .disk_config.disk_encryption = $enc else . end'
}
setup() {
  rm -rf "$dir"; mkdir -p "$dir"
  export OMARCHY_INSTALL_CONFIG="$dir/user_configuration.json" OMARCHY_INSTALL_CREDS="$dir/user_credentials.json" OMARCHY_INSTALL_STATE_DIR="$dir/state"
  unset OMARCHY_INSTALL_DEFER_PROVISIONING_FILE OMARCHY_INSTALL_FULL_NAME_FILE OMARCHY_INSTALL_EMAIL_FILE OMARCHY_INSTALL_ENCRYPT_FILE \
    OMARCHY_INSTALL_AUTHORIZED_KEYS_FILE OMARCHY_INSTALL_TAILSCALE_AUTHKEY_FILE
}
from_env_fails() { ( ctx_from_env ) 2>"$ERR" >/dev/null; local rc=$?; ((rc == 2)) && contains "$(cat "$ERR")" "$1"; }

section 'defer_provisioning flag from config'
setup; write_config "$(base_config true)"
ctx_from_env
check 'deferred' eq "$CTX_DEFER_PROVISIONING" true
check 'credentials synthesized' eq "$(jq -c . <<<"$CTX_USER_CREDENTIALS")" '{"users":[]}'
check 'no username' eq "$CTX_USERNAME" ''

section 'marker file arms deferred provisioning without credentials'
setup; write_config "$(base_config)"; touch "$dir/defer_provisioning"
OMARCHY_INSTALL_DEFER_PROVISIONING_FILE="$dir/defer_provisioning" ctx_from_env
check 'deferred' eq "$CTX_DEFER_PROVISIONING" true
check 'flag recorded in omarchy_install' eq "$(omarchy_install_get .defer_provisioning)" true

section 'absent marker file is not deferred provisioning'
setup; write_config "$(base_config)"; write_creds '{"users": [{"username": "jeff"}]}'
OMARCHY_INSTALL_DEFER_PROVISIONING_FILE="$dir/missing" ctx_from_env
check 'not deferred' eq "$CTX_DEFER_PROVISIONING" false
check 'username' eq "$CTX_USERNAME" jeff

section 'missing credentials without deferred provisioning fails'
setup; write_config "$(base_config)"
check 'configuration error' from_env_fails 'credentials file missing'

section 'deferred provisioning generates a throwaway LUKS passphrase'
setup; write_config "$(base_config true '{"encryption_type": "luks", "partitions": ["x"]}')"
ctx_from_env
password=$(user_configuration_get .disk_config.disk_encryption.encryption_password)
check 'password generated' test -n "$password"
check 'creds carry it' eq "$(jq -r .encryption_password <<<"$CTX_USER_CREDENTIALS")" "$password"
check 'arch config file carries it' eq "$(jq -r .disk_config.disk_encryption.encryption_password "$CTX_ARCH_CONFIG_PATH")" "$password"
check 'synthesized creds file carries it' eq "$(jq -r .encryption_password "$CTX_CREDS_PATH")" "$password"
check 'creds file private' eq "$(mode_of "$CTX_CREDS_PATH")" 600

section 'deferred provisioning reuses a rig-supplied passphrase'
setup; write_config "$(base_config true '{"encryption_type": "luks", "partitions": ["x"]}')"
write_creds '{"users": [], "encryption_password": "rig-secret"}'
ctx_from_env
check 'rig passphrase kept' eq "$(user_configuration_get .disk_config.disk_encryption.encryption_password)" rig-secret

section 'deferred provisioning discards account material'
setup; write_config "$(base_config true)"
write_creds '{"users": [{"username": "backdoor", "enc_password": "x", "sudo": true}], "root_enc_password": "x", "encryption_password": "rig-secret"}'
ctx_from_env
check 'users dropped' eq "$(jq -c .users <<<"$CTX_USER_CREDENTIALS")" '[]'
check 'root password dropped' eq "$(jq 'has("root_enc_password")' <<<"$CTX_USER_CREDENTIALS")" false
check 'passphrase kept' eq "$(jq -r .encryption_password <<<"$CTX_USER_CREDENTIALS")" rig-secret
check 'synthesized file has no users' eq "$(jq -c .users "$CTX_CREDS_PATH")" '[]'
check 'synthesized file has no root password' eq "$(jq 'has("root_enc_password")' "$CTX_CREDS_PATH")" false

section 'deferred provisioning strips account fields from the arch config'
setup
write_config "$(base_config true | jq '. + {"!users": [{"username": "rig"}], "!root-password": "hunter2", "root_enc_password": "x", "auth_config": {"users": [{"username": "rig"}], "root_enc_password": "x"}}')"
ctx_from_env
for key in '!users' '!root-password' root_enc_password users; do
  check "$key stripped" eq "$(jq --arg k "$key" 'has($k)' "$CTX_ARCH_CONFIG_PATH")" false
done
check 'auth_config emptied' eq "$(jq -c .auth_config "$CTX_ARCH_CONFIG_PATH")" '{}'

section 'deferred provisioning unencrypted touches nothing'
setup; write_config "$(base_config true)"
ctx_from_env
check 'no passphrase' eq "$(jq 'has("encryption_password")' <<<"$CTX_USER_CREDENTIALS")" false

section 'optional paths'
check 'unset is empty' eq "$(optional_path '')" ''
check 'missing is empty' eq "$(optional_path /does/not/exist/authorized_keys)" ''
touch "$TMP/present"
check 'existing is returned' eq "$(optional_path "$TMP/present")" "$TMP/present"

section 'defaults: target, mode, files'
setup; write_config "$(base_config)"; write_creds '{"users": [{"username": "jeff"}]}'
printf 'Jeff Example \n' >"$dir/name"; printf 'TRUE\n' >"$dir/encrypt"
OMARCHY_INSTALL_FULL_NAME_FILE="$dir/name" OMARCHY_INSTALL_ENCRYPT_FILE="$dir/encrypt" OMARCHY_INSTALL_AUTHORIZED_KEYS_FILE="$dir/nokeys" ctx_from_env
check 'target' eq "$CTX_TARGET" /mnt
check 'mode' eq "$CTX_MODE/$CTX_IS_PROTECTED" full_disk/false
check 'full name stripped' eq "$CTX_FULL_NAME" 'Jeff Example'
check 'encrypt flag' eq "$CTX_ENCRYPT" true
check 'absent authorized keys' eq "$CTX_AUTHORIZED_KEYS_PATH" ''
check 'arch config drops omarchy_install' eq "$(jq 'has("omarchy_install")' "$CTX_ARCH_CONFIG_PATH")" false
setup; write_config '{"disk_config": {"config_type": "pre_mounted_config", "mountpoint": "/mnt/x"}}'; write_creds '{"users": [{"username": "jeff"}]}'
ctx_from_env
check 'pre-mounted default intent' eq "$CTX_MODE/$CTX_TARGET/$(boot_intent enable_fallback)" protected//mnt/x/false

finish
