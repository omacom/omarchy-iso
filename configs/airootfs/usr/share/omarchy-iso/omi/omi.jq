# The Omi kit (omi.json) as tab-separated lines, one per thing, for omi.awk:
#
#   jq -r -f omi.jq omi.json > kit.tsv
#
# G grid, V view, M morph settings, Z gaze, A an animation and K its keys,
# O a mode and P its pieces. See omi.awk's load() for each line's fields.
  def j: map(tostring) | join(",");
  "G\t\(.grid)",
  "V\t\(.view | map(tostring) | join("\t"))",
  "M\t\(.morph.duration)\t\(.morph.stagger)\t\(.morph.ease | j)\t\(.morph.center[0])\t\(.morph.center[1])\t\(.morph.splitReach)\t\(.morph.rolePenalty)",
  (.gaze // empty | "Z\t\(.reach[0])\t\(.reach[1])\t\(.duration)\t\(.ease | j)\t\((.inside // [0,0,0,0]) | map(tostring) | join("\t"))\t\(.roles | join(","))"),
  (.animations | to_entries[] | .key as $n | .value as $a |
    "A\t\($n)\t\($a.duration)\t\($a.rest // 0)\t\(if ($a.ease | type) == "array" then ($a.ease | j) else $a.ease end)",
    ($a.keys | to_entries[] | .key as $i | .value[0] as $p | .value[1] | to_entries[] |
      "K\t\($n)\t\($i)\t\($p)\t\(.key)\t\(if (.value | type) == "array" then "@\(.value[0])*\(.value[1])" else .value end)")),
  (.modes[] | . as $m |
    "O\t\(.id)\t\(.kind // "state")\t\(.hold // "")\t\(.name)\t\(.label // .name)\t\(.group // "")\t\(.bounds | j)\t\(.anim // "")\t\(if .clip then ([.clip.x, .clip.y, .clip.w, .clip.h, (.clip.anim // "")] | j) else "" end)",
    (.pieces[] | "P\t\($m.id)\t\(.x)\t\(.y)\t\(.w)\t\(.h)\t\(.role)\t\(.opacity // 1)\t\(.anim // "")\t\(.delay // 0)\t\(.duration // "")\t\(if .clip then 1 else 0 end)\t\(.mx // 0)\t\(.my // 0)\t\(.dx // 0)\t\(.dy // 0)"))
