#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
preset="$ROOT/configs/presets/china.json"

for key in keyboard timezone language region; do
  [[ -n $(jq -r ".$key // empty" "$preset") ]] || { echo "the China preset lacks $key" >&2; exit 1; }
done
[[ $(jq -r .keyboard "$preset") == "Chinese (Simplified, Pinyin)" ]] || { echo "the China preset preselects the Pinyin keyboard row" >&2; exit 1; }
# The installer's language picker reads the same file: its keys, and the setup form's keyboard label.
extra=$(jq -r 'keys - ["keyboard", "timezone", "language", "language_prompt", "region"] | join(" ")' "$preset")
[[ -z $extra ]] || { echo "the China preset has keys the installer does not read: $extra" >&2; exit 1; }
[[ $(jq -r '.language_prompt | type' "$preset") == @(null|boolean) ]] || { echo "language_prompt is a boolean" >&2; exit 1; }
echo "ok - the China preset names the Pinyin keyboard, a timezone, a language and a region, in the picker's keys"

# The summary's region comes from the orchestrator's own lookup.
mkdir -p "$work/regions/cn" "$work/iso/orchestrator"
printf 'Asia/Shanghai\nAsia/Urumqi\n' >"$work/regions/cn/timezones"
cp "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/region.py" "$work/iso/orchestrator/"
: >"$work/iso/orchestrator/__init__.py"
sed -i "s|^REGIONS_DIR = .*|REGIONS_DIR = Path(\"$work/regions\")|" "$work/iso/orchestrator/region.py"
for case in "Asia/Shanghai - cn" "UTC - global" "UTC cn cn" "Europe/Copenhagen cn cn" "Asia/Hong_Kong cn global" "Hongkong cn global" "Asia/Macau cn global" "Asia/Macao cn global" "Asia/Taipei cn global" "ROC cn global"; do
  read -r timezone fallback expected <<<"$case"
  [[ $fallback == - ]] && fallback=""
  got=$(cd "$work/iso" && python3 -m orchestrator.region "$timezone" $fallback)
  [[ $got == "$expected" ]] || { echo "$timezone with preset '${fallback:-none}' gave $got, expected $expected" >&2; exit 1; }
done
echo "ok - the summary shows China's mirrors for a China ISO, except where the timezone is Hong Kong, Macau or Taiwan"

# Without a preset the installer writes the install configuration it always did.
! grep -q 'preset' <(sed -n '/cat <<-_EOF_ >user_configuration.json/,/^_EOF_/p' "$ROOT/configs/airootfs/root/configurator") ||
  { echo "a preset reaches the install configuration the configurator writes" >&2; exit 1; }
echo "ok - presets never change the install configuration the configurator writes"

# The configurator hands the preset's keyboard and timezone to the setup form's defaults, and a build without a preset hands it none.
preset_block=$(sed -n '/^ISO_PRESET=/,/^\[\[ -z \$preset_timezone \]\]/p' "$ROOT/configs/airootfs/root/configurator")
got=$(ISO_PRESET="$preset" bash -c "$preset_block"$'\nprintf "%s|%s|%s" "$OMARCHY_FORM_KEYBOARD_DEFAULT" "$OMARCHY_FORM_TIMEZONE_DEFAULT" "$preset_region"')
[[ $got == "Chinese (Simplified, Pinyin)|Asia/Shanghai|cn" ]] || { echo "the configurator read the China preset as '$got'" >&2; exit 1; }
got=$(ISO_PRESET="$work/none.json" bash -c "$preset_block"$'\nprintf "%s|%s|%s" "${OMARCHY_FORM_KEYBOARD_DEFAULT-unset}" "${OMARCHY_FORM_TIMEZONE_DEFAULT-unset}" "$preset_region"')
[[ $got == "unset|unset|" ]] || { echo "the configurator without a preset read '$got'" >&2; exit 1; }
echo "ok - the configurator preselects the preset's keyboard and timezone, and nothing without one"

# A preset build bundles the region's additions its repositories publish for the architecture, and nothing for a build without a preset.
block=$(sed -n '/^preset_region=""$/,/^fi$/p' "$ROOT/builder/build-iso.sh")
mkdir -p "$work/build/configs/presets" "$work/build/cache/airootfs/usr/share/omarchy-iso/regions/cn" "$work/build/bin"
cp "$preset" "$work/build/configs/presets/china.json"
printf '# additions\nwechat-bin\nwps-office-cn\nfeishu-bin\n' >"$work/build/cache/airootfs/usr/share/omarchy-iso/regions/cn/packages-add"
cat >"$work/build/bin/pacman" <<'SH'
#!/bin/bash
[[ " $* " == *" -Sy "* ]] && exit "${SYNC_STATUS:-0}"
for name in $PUBLISHED; do [[ ${!#} == "$name" ]] && exit 0; done
exit 1
SH
chmod +x "$work/build/bin/pacman"
bundle() {
  local block_for_test=${block//\/configs\/presets/$work/build/configs/presets}
  export SYNC_STATUS
  PATH="$work/build/bin:$PATH" PUBLISHED="$1" OMARCHY_ISO_PRESET="$2" bash -c 'set -euo pipefail; build_cache_dir=$1; online_pacman_conf=x; OMARCHY_ARCH=aarch64; all_packages=(mpv); eval "$2"; printf "%s " "${all_packages[@]}"' _ "$work/build/cache" "$block_for_test" 2>/dev/null
}
[[ $(bundle "wechat-bin wps-office-cn" china) == "mpv wechat-bin wps-office-cn " ]] || { echo "a China build bundles its published additions: $(bundle "wechat-bin wps-office-cn" china)" >&2; exit 1; }
[[ $(bundle "wechat-bin" china) == "mpv wechat-bin " ]] || { echo "a China build leaves out additions with no build for the architecture" >&2; exit 1; }
[[ $(bundle "wechat-bin wps-office-cn" "") == "mpv " ]] || { echo "a build without a preset bundles no region additions" >&2; exit 1; }
if SYNC_STATUS=1 bundle "wechat-bin" china >/dev/null; then
  echo "a China build stops when it cannot read the repositories" >&2
  exit 1
fi
echo "ok - a China build bundles the region's published additions, a global build none, and a failed sync stops the build"
