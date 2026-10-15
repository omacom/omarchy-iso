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
echo "ok - the China preset names the Pinyin keyboard, a timezone, a language and a region"

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
