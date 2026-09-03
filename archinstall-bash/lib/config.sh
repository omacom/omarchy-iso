# shellcheck shell=bash
# Configuration loading. Port of lib/args.py (ArchConfigHandler._parse_config,
# ArchConfig.from_config) and the parse_arg() methods of lib/models/*.py for
# the JSON that `archinstall --config user_configuration.json
# --creds user_credentials.json` consumes. Parsed with jq into flat bash state.
#
# Not ported: LVM layouts, FIDO2/HSM encryption, profiles, the interactive
# menu, encrypted credential files, bootloader installation (Omarchy installs
# Limine itself), encrypting anything but the root partition, modifying
# existing partition tables (only wipe: true or pre_mounted_config).

CONFIG_JSON='{}'

# Plain settings (ArchConfig fields)
CFG_HOSTNAME='' CFG_TIMEZONE='UTC' CFG_NTP=true
CFG_KERNELS=() CFG_PACKAGES=() CFG_SERVICES=() CFG_CUSTOM_COMMANDS=()
CFG_SWAP_ENABLED=false
CFG_HAS_PACMAN_CONFIG=false CFG_PARALLEL_DOWNLOADS=5 CFG_PACMAN_COLOR=true
CFG_LOCALE_KB='' CFG_LOCALE_LANG=en_US.UTF-8 CFG_LOCALE_ENC=UTF-8 CFG_LOCALE_FONT=default8x16
CFG_HAS_MIRROR_CONFIG=false
CFG_MIRROR_CUSTOM_SERVERS=() CFG_MIRROR_REGIONS=() CFG_MIRROR_OPTIONAL_REPOS=()
CFG_MIRROR_CUSTOM_REPOS=() # "name<TAB>url<TAB>SignCheck<TAB>SignOption"
CFG_BOOTLOADER='' CFG_BOOT_REMOVABLE=false
CFG_NETWORK_TYPE=''
CFG_HAS_APP_CONFIG=false CFG_AUDIO='' CFG_BLUETOOTH=false
CFG_ROOT_ENC_PASSWORD=''
USER_NAME=() USER_ENC_PASSWORD=() USER_SUDO=() USER_GROUPS=()

# Disk layout (DiskLayoutConfiguration)
DISK_CONFIG_PRESENT=false DISK_CONFIG_TYPE='' DISK_MOUNTPOINT=''
DEV_PATH=() DEV_WIPE=()
# One entry per partition; PART_DEV indexes DEV_*. Sizes in bytes.
PART_DEV=() PART_OBJID=() PART_STATUS=() PART_TYPE=() PART_START=() PART_LENGTH=()
PART_FS=() PART_MOUNTPOINT=() PART_MOUNT_OPTIONS=() PART_FLAGS=() PART_SUBVOLS=()
PART_DEVPATH=() PART_PARTN=() PART_PARTUUID=() PART_UUID=()
# DiskEncryption
ENC_TYPE=no_encryption ENC_PASSWORD='' ENC_ITER_TIME=10000 ENC_PARTS=()

ENC_IDENTIFIER=ainst

cfg() {
  jq -r "$1" <<<"$CONFIG_JSON"
}


# Read lines of `jq -r` output into an array (newline separated, no empties).
_cfg_array() {
  local -n _out=$1
  mapfile -t _out < <(cfg "$2 // [] | .[] | select(. != null and . != \"\") | tostring")
}

# ArchConfigHandler._parse_config(): config first, credentials layered on top.
config_load() {
  local config_file=${1:-} creds_file=${2:-}
  CONFIG_JSON='{}'
  if [[ -n $config_file ]]; then
    [[ -f $config_file ]] || die "config file not found: $config_file"
    CONFIG_JSON=$(jq -c . "$config_file") || die "invalid JSON in $config_file"
  fi
  if [[ -n $creds_file ]]; then
    [[ -f $creds_file ]] || die "credentials file not found: $creds_file"
    [[ $(head -c1 "$creds_file") != '$' ]] || die 'encrypted credentials files are not supported by this port'
    CONFIG_JSON=$(jq -c -s '.[0] + .[1]' <(printf '%s' "$CONFIG_JSON") "$creds_file") || die "invalid JSON in $creds_file"
  fi
  config_parse
}

config_parse() {
  local v

  # LocaleConfiguration.parse_arg: defaults from the live system.
  CFG_LOCALE_KB=$(locale_get_kb_layout)
  [[ -n $CFG_LOCALE_KB ]] || CFG_LOCALE_KB=us
  v=$(cfg '.locale_config.kb_layout // .kb_layout // empty'); [[ -n $v ]] && CFG_LOCALE_KB=$v
  v=$(cfg '.locale_config.sys_lang // .sys_lang // empty'); [[ -n $v ]] && CFG_LOCALE_LANG=$v
  v=$(cfg '.locale_config.sys_enc // .sys_enc // empty'); [[ -n $v ]] && CFG_LOCALE_ENC=$v
  v=$(cfg '.locale_config.console_font // .console_font // empty'); [[ -n $v ]] && CFG_LOCALE_FONT=$v

  CFG_HOSTNAME=$(cfg '.hostname // empty')
  _cfg_array CFG_KERNELS '.kernels'
  CFG_NTP=$(cfg 'if has("ntp") then .ntp else true end')
  _cfg_array CFG_PACKAGES '.packages'
  _cfg_array CFG_SERVICES '.services'
  _cfg_array CFG_CUSTOM_COMMANDS '.custom_commands'
  CFG_TIMEZONE=$(cfg '.timezone // "UTC"')
  [[ -n $CFG_TIMEZONE ]] || CFG_TIMEZONE=UTC

  # PacmanConfiguration (or the deprecated top-level parallel_downloads)
  if [[ $(cfg '.pacman_config // empty | type') == object ]]; then
    CFG_HAS_PACMAN_CONFIG=true
    v=$(cfg '.pacman_config.parallel_downloads // empty'); [[ -n $v ]] && CFG_PARALLEL_DOWNLOADS=$v
    v=$(cfg '.pacman_config.color // empty'); [[ -n $v ]] && CFG_PACMAN_COLOR=$v
  elif [[ $(cfg '.parallel_downloads // 0') != 0 ]]; then
    CFG_HAS_PACMAN_CONFIG=true
    CFG_PARALLEL_DOWNLOADS=$(cfg '.parallel_downloads')
  fi

  # ZramConfiguration.parse_arg: bool or {enabled}. A configured algorithm is
  # ignored: zram tuning is the vendor drop-in's business (installer_setup_swap).
  case $(cfg '.swap | type') in
    boolean) CFG_SWAP_ENABLED=$(cfg '.swap') ;;
    object) CFG_SWAP_ENABLED=$(cfg 'if .swap | has("enabled") then .swap.enabled else true end') ;;
  esac

  # MirrorConfiguration
  if [[ $(cfg '.mirror_config | type') == object ]]; then
    CFG_HAS_MIRROR_CONFIG=true
    _cfg_array CFG_MIRROR_CUSTOM_SERVERS '.mirror_config.custom_servers | map(.url)'
    _cfg_array CFG_MIRROR_REGIONS '.mirror_config.mirror_regions // {} | keys'
    _cfg_array CFG_MIRROR_OPTIONAL_REPOS '.mirror_config.optional_repositories'
    mapfile -t CFG_MIRROR_CUSTOM_REPOS < <(cfg '(.mirror_config.custom_repositories // .mirror_config.custom_mirrors // [])[] | [.name, .url, .sign_check, .sign_option] | map(tostring) | join("\u001f")')
  fi
  local r
  for r in $(cfg '."additional-repositories" // [] | .[]'); do
    list_contains "${CFG_MIRROR_OPTIONAL_REPOS[*]}" "$r" || CFG_MIRROR_OPTIONAL_REPOS+=("$r")
  done

  # NetworkConfiguration
  CFG_NETWORK_TYPE=$(cfg '.network_config.type // empty')

  # BootloaderConfiguration: recorded for the caller (Omarchy installs Limine
  # itself); this port installs no bootloader.
  if [[ $(cfg '.bootloader_config | type') == object ]]; then
    CFG_BOOTLOADER=$(bootloader_from_arg "$(cfg '.bootloader_config.bootloader // empty')")
    CFG_BOOT_REMOVABLE=$(cfg '.bootloader_config.removable // false')
  elif [[ -n $(cfg '.bootloader // empty') ]]; then
    CFG_BOOTLOADER=$(bootloader_from_arg "$(cfg '.bootloader')")
    CFG_BOOT_REMOVABLE=true
  fi
  [[ -n $(cfg '.bootloader_config.plymouth // empty') ]] && warn 'bootloader_config.plymouth is not supported by this port and will be ignored'

  # ApplicationConfiguration (+ deprecated top-level audio_config)
  if [[ $(cfg '.app_config | type') == object || $(cfg '.audio_config | type') == object ]]; then
    CFG_HAS_APP_CONFIG=true
    CFG_AUDIO=$(cfg '.app_config.audio_config.audio // .audio_config.audio // empty')
    CFG_BLUETOOTH=$(cfg '.app_config.bluetooth_config.enabled // false')
    [[ -n $CFG_AUDIO && $CFG_AUDIO != pipewire && $CFG_AUDIO != 'No audio server' ]] && die "audio server $CFG_AUDIO is not supported by this port (pipewire only)"
    for v in power_management_config print_service_config firewall_config fonts_config; do
      [[ $(cfg ".app_config.$v // empty") ]] && warn "app_config.$v is not supported by this port and will be ignored"
    done
  fi

  # AuthenticationConfiguration + deprecated root password / users keys.
  # Credentials (merged in config_load) carry root_enc_password and users.
  CFG_ROOT_ENC_PASSWORD=$(cfg '.auth_config.root_enc_password // .root_enc_password // empty')
  v=$(cfg '."!root-password" // empty')
  [[ -n $v ]] && CFG_ROOT_ENC_PASSWORD=$(password_hash "$v")
  [[ $(cfg '.auth_config.u2f_config // empty') ]] && warn 'auth_config.u2f_config is not supported by this port and will be ignored'
  config_parse_users

  # Disk layout and encryption
  config_parse_disk

  local profile
  profile=$(cfg '.profile_config.profile // {} | if type == "object" then (.main // empty) else . end')
  [[ -n $profile ]] && warn "profile_config ($profile) is not supported by this port and will be ignored"
  [[ -n $(cfg '.script // empty') && $(cfg '.script') != guided ]] && warn "script $(cfg '.script') is not available; running guided"
  return 0
}

# User.parse_arguments(): `users` (enc_password) or deprecated `!users`
# (`!password` plaintext). Entries without a username or password are skipped.
config_parse_users() {
  USER_NAME=() USER_ENC_PASSWORD=() USER_SUDO=() USER_GROUPS=()
  local key='.users'
  [[ $(cfg '.users | type') == array ]] || key='."!users"'
  [[ $(cfg "$key | type") == array ]] || return 0
  local username plaintext enc sudo groups
  while IFS=$'\x1f' read -r username plaintext enc sudo groups; do
    [[ -n $username ]] || continue
    if [[ -n $plaintext ]]; then
      enc=$(password_hash "$plaintext")
    fi
    [[ -n $enc ]] || continue
    USER_NAME+=("$username")
    USER_ENC_PASSWORD+=("$enc")
    USER_SUDO+=("$sudo")
    USER_GROUPS+=("$groups")
  done < <(cfg "${key}[] | [(.username // \"\"), (.\"!password\" // \"\"), (.enc_password // \"\"), ((.sudo // false) == true), ((.groups // []) | join(\" \"))] | map(tostring) | join(\"\\u001f\")")
}

# DiskLayoutConfiguration.parse_arg()
config_parse_disk() {
  DISK_CONFIG_PRESENT=false DISK_CONFIG_TYPE='' DISK_MOUNTPOINT=''
  DEV_PATH=() DEV_WIPE=()
  PART_DEV=() PART_OBJID=() PART_STATUS=() PART_TYPE=() PART_START=() PART_LENGTH=()
  PART_FS=() PART_MOUNTPOINT=() PART_MOUNT_OPTIONS=() PART_FLAGS=() PART_SUBVOLS=()
  PART_DEVPATH=() PART_PARTN=() PART_PARTUUID=() PART_UUID=()
  ENC_TYPE=no_encryption ENC_PASSWORD='' ENC_ITER_TIME=10000 ENC_PARTS=()

  [[ $(cfg '.disk_config | type') == object && $(cfg '.disk_config | length') -gt 0 ]] || return 0
  DISK_CONFIG_PRESENT=true
  DISK_CONFIG_TYPE=$(cfg '.disk_config.config_type // empty')
  [[ -n $DISK_CONFIG_TYPE ]] || die 'Missing disk layout configuration: config_type'

  if [[ $DISK_CONFIG_TYPE == pre_mounted_config ]]; then
    DISK_MOUNTPOINT=$(cfg '.disk_config.mountpoint // empty')
    [[ -n $DISK_MOUNTPOINT ]] || die 'Must set a mountpoint when layout type is pre-mount'
    disk_detect_pre_mounted_mods "$DISK_MOUNTPOINT"
    return 0
  fi

  [[ $(cfg '.disk_config.lvm_config // empty') ]] && die 'lvm_config is not supported by this port'

  local device wipe
  while IFS=$'\x1f' read -r device wipe; do
    [[ -n $device ]] || continue
    [[ -b $device ]] || die "device not found: $device"
    [[ $wipe == true ]] || die "device_modifications without wipe: true (adding partitions to an existing table) is not supported by this port; use pre_mounted_config"
    DEV_PATH+=("$device")
    DEV_WIPE+=("$wipe")
  done < <(cfg '.disk_config.device_modifications // [] | .[] | [(.device // ""), ((.wipe // false) == true)] | map(tostring) | join("\u001f")')

  local d objid status type start length fs mountpoint options flags devpath subvols
  while IFS=$'\x1f' read -r d objid status type start length fs mountpoint options flags devpath subvols; do
    [[ -n $status ]] || continue
    PART_DEV+=("$d")
    PART_OBJID+=("$objid")
    PART_STATUS+=("$status")
    PART_TYPE+=("$type")
    PART_START+=("$start")
    PART_LENGTH+=("$length")
    PART_FS+=("$fs")
    PART_MOUNTPOINT+=("$mountpoint")
    PART_MOUNT_OPTIONS+=("$options")
    PART_FLAGS+=("$(config_normalize_flags "$flags")")
    PART_DEVPATH+=("$devpath")
    PART_SUBVOLS+=("$subvols")
    PART_PARTN+=('') PART_PARTUUID+=('') PART_UUID+=('')
  done < <(cfg '
    def ub: {"B":1,"kB":1000,"MB":1000000,"GB":1000000000,"TB":1000000000000,"PB":1000000000000000,
             "KiB":1024,"MiB":1048576,"GiB":1073741824,"TiB":1099511627776,"PiB":1125899906842624}[.]
             // error("unknown size unit \(.)");
    def bytes: if .unit == "sectors" then .value * (.sector_size.value * (.sector_size.unit | ub))
               else .value * (.unit | ub) end | floor;
    (.disk_config.device_modifications // []) | to_entries[] | .key as $d
    | (.value.partitions // [])[]
    | [ $d, (.obj_id // ""), .status, (.type // "primary"), (.start | bytes), (.size | bytes),
        (.fs_type // ""), (.mountpoint // ""), ((.mount_options // []) | join(",")),
        ((.flags // []) | map(ascii_downcase) | join(" ")), (.dev_path // ""),
        ((.btrfs // []) | map(select(.name and .mountpoint)) | map("\(.name)=\(.mountpoint)") | join(" ")) ]
    | map(tostring) | join("\u001f")')

  local i
  for i in "${!PART_STATUS[@]}"; do
    case ${PART_STATUS[i]} in
      create) ;;
      existing|modify|delete) die "partition status ${PART_STATUS[i]} is not supported by this port (wiped disks only)" ;;
      *) die "unknown partition status: ${PART_STATUS[i]}" ;;
    esac
    [[ -n ${PART_FS[i]} ]] && ! fs_type_known "${PART_FS[i]}" && die "unknown fs_type: ${PART_FS[i]}"
  done
  config_validate_layout

  # DiskEncryption.parse_arg()
  if [[ $(cfg '.disk_config.disk_encryption // empty | type') == object ]]; then
    config_parse_encryption '.disk_config.disk_encryption'
  elif [[ $(cfg '.disk_encryption // empty | type') == object ]]; then
    config_parse_encryption '.disk_encryption' # deprecated top-level key
  fi

  [[ -n $(cfg '.disk_config.btrfs_options.snapshot_config.type // empty') ]] &&
    warn 'btrfs_options.snapshot_config (snapper/timeshift) is not supported by this port and will be ignored'
  return 0
}

# PartitionFlag.from_string(): boot, esp, bls_boot (xbootldr), linux-home, swap.
config_normalize_flags() {
  local out='' f
  for f in $1; do
    case $f in
      boot|esp|swap) ;;
      bls_boot|xbootldr) f=xbootldr ;;
      linux-home|linux_home) f=linux-home ;;
      *) debug "Partition flag not supported: $f"; continue ;;
    esac
    out+="$f "
  done
  printf '%s' "${out% }"
}

# The geometry checks from DiskLayoutConfiguration.parse_arg().
config_validate_layout() {
  local d i prev_end total last_end mib=1048576 table
  table=$(fs_partition_table)
  for d in "${!DEV_PATH[@]}"; do
    prev_end=-1 last_end=-1
    for i in $(disk_partition_indexes_sorted "$d"); do
      ((PART_START[i] >= mib)) || die 'First partition must start at no less than 1 MiB'
      ((prev_end < 0 || PART_START[i] >= prev_end)) || die 'Partitions overlap'
      ((PART_START[i] % mib == 0 && PART_LENGTH[i] % mib == 0)) || die 'Partition is misaligned'
      last_end=$((PART_START[i] + PART_LENGTH[i]))
      prev_end=$last_end
    done
    ((last_end < 0)) && continue
    total=$(disk_size_bytes "${DEV_PATH[d]}")
    if [[ $table == gpt ]]; then
      ((last_end <= total - mib)) || die 'Partition overlaps backup GPT header'
    else
      ((last_end <= total - total % mib)) || die 'Partition too large for device'
    fi
  done
}

config_parse_encryption() {
  local key=$1 enc_type objid i
  enc_type=$(cfg "$key.encryption_type // \"no_encryption\"")
  [[ $enc_type == no_encryption ]] && return 0
  [[ $enc_type == luks ]] || die "encryption_type $enc_type is not supported by this port (LUKS only)"
  [[ $(cfg "$key.hsm_device // empty") ]] && die 'hsm_device (FIDO2) encryption is not supported by this port'

  # Upstream silently drops the whole encryption block when no password was
  # supplied; installing unencrypted when encryption was requested is a bug,
  # not a feature, so refuse instead.
  ENC_PASSWORD=$(cfg '.encryption_password // empty')
  [[ -n $ENC_PASSWORD ]] || ENC_PASSWORD=$(cfg "$key.encryption_password // empty")
  [[ -n $ENC_PASSWORD ]] || die 'disk encryption requested but no encryption_password supplied (user_credentials.json)'

  ENC_TYPE=luks
  ENC_PARTS=()
  for objid in $(cfg "$key.partitions // [] | .[]"); do
    for i in "${!PART_OBJID[@]}"; do
      [[ ${PART_OBJID[i]} == "$objid" ]] && ENC_PARTS+=("$i")
    done
  done
  ((${#ENC_PARTS[@]})) || die 'Luks encryption requires partitions to be defined'
  for i in "${ENC_PARTS[@]}"; do
    part_is_root "$i" || die "only the root partition may be encrypted in this port (${PART_DEVPATH[i]:-${PART_OBJID[i]}} is not root)"
  done
  local it
  it=$(cfg "$key.iter_time // empty")
  [[ -n $it ]] && ENC_ITER_TIME=$it
  return 0
}

# Bootloader.from_arg(), names only.
bootloader_from_arg() {
  # Omarchy installs Limine and nothing else; refuse anything foreign here,
  # in the config parse, instead of three phases later with the disk already
  # formatted.
  case ${1,,} in
    limine) printf 'limine' ;;
    'no bootloader'|no_bootloader|none) printf 'no_bootloader' ;;
    *) die "Unsupported bootloader \"$1\": this port installs Limine (or no bootloader)" ;;
  esac
}

# ── partition model helpers (PartitionModification / DeviceModification) ──────

part_is_root() {
  local i=$1
  if [[ -n ${PART_MOUNTPOINT[i]} ]]; then
    [[ ${PART_MOUNTPOINT[i]} == / ]]
  else
    [[ -n $(part_root_subvol "$i") ]]
  fi
}

part_is_home() {
  [[ ${PART_MOUNTPOINT[$1]} == /home ]]
}

part_is_efi() {
  list_contains "${PART_FLAGS[$1]}" esp
}

part_is_boot() {
  list_contains "${PART_FLAGS[$1]}" boot
}

part_is_swap() {
  [[ ${PART_FS[$1]} == linux-swap ]]
}

part_is_create_or_modify() {
  [[ ${PART_STATUS[$1]} == create ]]
}

part_is_encrypted() {
  local i
  for i in "${ENC_PARTS[@]}"; do
    [[ $i == "$1" ]] && return 0
  done
  return 1
}

# Name of the subvolume mounted at / (SubvolumeModification.is_root()).
part_root_subvol() {
  local sv
  for sv in ${PART_SUBVOLS[$1]}; do
    [[ ${sv#*=} == / ]] && { printf '%s' "${sv%%=*}"; return 0; }
  done
  return 1
}

part_mapper_name() {
  local i=$1
  if part_is_root "$i"; then
    printf 'root'
  elif part_is_home "$i"; then
    printf 'home'
  elif [[ -n ${PART_DEVPATH[i]} ]]; then
    printf '%s%s' "$ENC_IDENTIFIER" "${PART_DEVPATH[i]##*/}"
  fi
}

part_mapper_dev() {
  printf '/dev/mapper/%s' "$(part_mapper_name "$1")"
}


part_safe_fs_type() {
  [[ -n ${PART_FS[$1]} ]] || die 'File system type is not set'
  printf '%s' "${PART_FS[$1]}"
}

# Indexes of the partitions on device $1, by start offset.
disk_partition_indexes_sorted() {
  local d=$1 i
  for i in "${!PART_DEV[@]}"; do
    [[ ${PART_DEV[i]} == "$d" ]] || continue
    printf '%d %d\n' "${PART_START[i]}" "$i"
  done | sort -n -k1,1 | awk '{ print $2 }'
}

disk_device_has_partitions() {
  local i
  for i in "${!PART_DEV[@]}"; do
    [[ ${PART_DEV[i]} == "$1" ]] && return 0
  done
  return 1
}

# DeviceModification.get_*_partition() across all devices (Installer._get_*).
installer_get_efi_partition() {
  local i
  for i in "${!PART_DEV[@]}"; do
    part_is_efi "$i" && [[ -n ${PART_MOUNTPOINT[i]} ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

installer_get_boot_partition() {
  local i
  for i in "${!PART_DEV[@]}"; do
    part_is_boot "$i" && [[ -n ${PART_MOUNTPOINT[i]} ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

installer_get_root() {
  local i
  for i in "${!PART_DEV[@]}"; do
    part_is_root "$i" && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# DiskLayoutConfiguration.has_default_btrfs_vols(): a created/modified btrfs
# partition with subvolume @ mounted at /.
disk_has_default_btrfs_vols() {
  local i
  for i in "${!PART_DEV[@]}"; do
    part_is_create_or_modify "$i" && [[ ${PART_FS[i]} == btrfs && $(part_root_subvol "$i") == @ ]] && return 0
  done
  return 1
}

disk_is_pre_mount() {
  [[ $DISK_CONFIG_TYPE == pre_mounted_config ]]
}


# DeviceHandler.detect_pre_mounted_mods(): describe whatever is mounted below
# the target as existing partitions, with mountpoints rebased to /.
disk_detect_pre_mounted_mods() {
  local base=${1%/} path pkname fstype parttype partn partuuid uuid start size mps mp
  [[ -n $base ]] || base=/
  while IFS=$'\x1f' read -r path pkname fstype parttype partn partuuid uuid start size mps; do
    [[ -n $path && -n $pkname ]] || continue
    local hit='' rel=''
    for mp in $mps; do
      if [[ $mp == "$base" || $mp == "$base"/* ]]; then
        hit=$mp
        break
      fi
    done
    [[ -n $hit ]] || continue
    rel=/${hit#"$base"}
    rel=${rel//\/\//\/}

    local d='' j
    for j in "${!DEV_PATH[@]}"; do
      [[ ${DEV_PATH[j]} == "/dev/$pkname" ]] && d=$j
    done
    if [[ -z $d ]]; then
      DEV_PATH+=("/dev/$pkname")
      DEV_WIPE+=(false)
      d=$((${#DEV_PATH[@]} - 1))
    fi

    local flags='' mountpoint='' subvols=''
    case ${parttype,,} in
      "${GPT_TYPE_ESP,,}") flags='boot esp' ;;
      "${GPT_TYPE_XBOOTLDR,,}") flags='xbootldr' ;;
      "${GPT_TYPE_LINUX_HOME,,}") flags='linux-home' ;;
      "${GPT_TYPE_LINUX_SWAP,,}") flags='swap' ;;
      0xef|0xc|0xb) flags='boot esp' ;;
    esac
    if [[ $fstype == btrfs ]]; then
      subvols=$(disk_btrfs_subvols_mounted_under "$path" "$base")
    fi
    [[ -z $subvols ]] && mountpoint=$rel

    PART_DEV+=("$d")
    PART_OBJID+=("$(cat /proc/sys/kernel/random/uuid)")
    PART_STATUS+=(existing)
    PART_TYPE+=(primary)
    PART_START+=("$((start * 512))")
    PART_LENGTH+=("$size")
    PART_FS+=("$fstype")
    PART_MOUNTPOINT+=("$mountpoint")
    PART_MOUNT_OPTIONS+=('')
    PART_FLAGS+=("$flags")
    PART_SUBVOLS+=("$subvols")
    PART_DEVPATH+=("$path")
    PART_PARTN+=("$partn")
    PART_PARTUUID+=("$partuuid")
    PART_UUID+=("$uuid")
  done < <(lsblk -J -b -o PATH,PKNAME,TYPE,FSTYPE,PARTTYPE,PARTN,PARTUUID,UUID,START,SIZE,MOUNTPOINTS 2>/dev/null |
    jq -r '[.. | objects | select(.type == "part")][]
           | [.path, (.pkname // ""), (.fstype // ""), (.parttype // ""), (.partn // ""), (.partuuid // ""),
              (.uuid // ""), (.start // 0), (.size // 0), ((.mountpoints // []) | map(select(. != null)) | join(" "))]
           | map(tostring) | join("\u001f")')
}

# "name=mountpoint ..." for the btrfs subvolumes of $1 mounted below $2.
disk_btrfs_subvols_mounted_under() {
  local dev=$1 base=${2%/} out='' fsroot target
  while IFS=' ' read -r fsroot target; do
    [[ -n $fsroot && -n $target ]] || continue
    [[ $target == "$base" || $target == "$base"/* ]] || continue
    local rel=/${target#"$base"}
    rel=${rel//\/\//\/}
    out+="${fsroot#/}=$rel "
  done < <(findmnt -rn -S "$dev" -o FSROOT,TARGET 2>/dev/null)
  printf '%s' "${out% }"
}

# ArchConfig.save(): keep a copy of the effective config next to the log,
# with credentials stripped.
config_save() {
  local dest=${1:-$ARCHINSTALL_LOG_DIR}
  mkdir -p "$dest" 2>/dev/null || return 0
  jq 'del(.users, ."!users", ."!root-password", .root_enc_password, .encryption_password, .auth_config.root_enc_password, .auth_config.users)' \
    <<<"$CONFIG_JSON" >"$dest/user_configuration.json" 2>/dev/null || true
}

config_summary() {
  local i
  printf 'Hostname:   %s\nTimezone:   %s\nKernels:    %s\nLocale:     %s %s (keymap %s)\nBootloader: %s (removable=%s)\nSwap:       zram=%s\nUsers:      %s\n' \
    "$CFG_HOSTNAME" "$CFG_TIMEZONE" "${CFG_KERNELS[*]:-linux}" "$CFG_LOCALE_LANG" "$CFG_LOCALE_ENC" "$CFG_LOCALE_KB" \
    "${CFG_BOOTLOADER:-none}" "$CFG_BOOT_REMOVABLE" "$CFG_SWAP_ENABLED" "${USER_NAME[*]:-<none>}"
  printf 'Disk:       %s' "${DISK_CONFIG_TYPE:-<none>}"
  [[ -n $DISK_MOUNTPOINT ]] && printf ' at %s' "$DISK_MOUNTPOINT"
  printf '\n'
  for i in "${!PART_DEV[@]}"; do
    printf '  %-8s %-10s %-14s %12s+%-12s fs=%-10s mount=%-10s flags=[%s] subvols=[%s]%s\n' \
      "${PART_STATUS[i]}" "${DEV_PATH[${PART_DEV[i]}]}" "${PART_DEVPATH[i]:--}" "${PART_START[i]}" "${PART_LENGTH[i]}" \
      "${PART_FS[i]:--}" "${PART_MOUNTPOINT[i]:--}" "${PART_FLAGS[i]}" "${PART_SUBVOLS[i]}" \
      "$(part_is_encrypted "$i" && printf ' LUKS')"
  done
}
