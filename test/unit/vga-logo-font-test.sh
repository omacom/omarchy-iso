#!/bin/bash
#
# vga-logo-font.py draws the logo at half size for the VGA text console: each
# cell a 2x4 piece of the logo's pixel grid (a block glyph is one column by
# two pixels), in a 256-glyph 8x16 PSF2 font of its own whose Unicode table
# maps the pieces to U+E000 onwards. These cases run it on a fixture and on
# the real logo, then read the font back:
#
# - the header: PSF2, 256 glyphs of 8x16, with a Unicode table;
# - ASCII from the base font, at its own code;
# - each piece's bitmap: the left logo column in the glyph's left 4 pixels,
#   the right one in the right 4, each logo row 4 pixel rows high;
# - pieces whose ink runs into the next cell in 0xC0-0xDF, where the VGA
#   repeats the 8th pixel column in the 9th, and no others there;
# - the text: the pieces in private-use characters, a line per cell row;
# - the real logo: 41x5 cells, which on a 1280x800 panel is the greeter's size;
# - refusals: a logo with other glyphs than blocks, a base font not 8x16.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOOL="$ROOT/configs/airootfs/usr/share/omarchy-iso/vga-logo-font.py"
BASE=/usr/share/kbd/consolefonts/default8x16.psfu.gz

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

if [[ ! -r $BASE ]]; then
  echo "skip: no $BASE here (kbd)"
  exit 0
fi

# Fixture, 6 columns by 2 lines = 6x4 logo pixels = 3 cells by 1 row:
#   cell 1 (columns 1-2): the left column full, the right its lower half,
#          which runs on into cell 2's left column
#   cell 2 (columns 3-4): the left column's lower half, the right blank
#   cell 3 (columns 5-6): the left column full, the right blank
printf '%s\n' '█   █ ' '███ █ ' >"$work/logo.txt"
python3 "$TOOL" "$work/logo.txt" "$BASE" "$work/out" 2>"$work/err" || { fail "fixture: $(cat "$work/err")"; exit 1; }

python3 - "$work/out" <<'EOF' >"$work/report" || true
import struct, sys
out = sys.argv[1]
d = open(f"{out}/vga.psf", "rb").read()
magic, version, header, flags, count, size, height, width = struct.unpack("<4sIIIIIII", d[:32])
print("header", magic.hex(), count, size, height, width, flags & 1)
glyphs = [d[header + i * size:header + (i + 1) * size] for i in range(count)]
codes = {}
for slot, entry in enumerate(d[header + count * size:].split(b"\xff")[:count]):
    for ch in entry.decode():
        codes[ord(ch)] = slot
print("A", glyphs[codes[ord("A")]].hex(), codes[ord("A")])
for n in range(3):
    if 0xE000 + n in codes:
        slot = codes[0xE000 + n]
        print(f"piece{n}", f"{slot:02x}", glyphs[slot].hex())
inv = {}
for slot, entry in enumerate(d[header + count * size:].split(b"\xff")[:count]):
    inv[slot] = entry.decode()
print("blocks", " ".join(f"{ord(inv[s][0]):x}" for s in (0xDB, 0xDC, 0xDF)), "kept")
pieces = {slot for slot, chars in inv.items() if chars and 0xE000 <= ord(chars[0]) < 0xF000}
bad = [slot for slot in range(0x20, 0x100) if slot not in pieces and slot not in (0x7F, 0xFE) and inv[slot][:1] != bytes([slot]).decode("cp437")]
print("cp437 kept" if not bad else f"cp437 changed {[hex(b) for b in bad]}")
text = open(f"{out}/vga.txt", encoding="utf-8").read()
print("text", [hex(ord(c)) for c in text.rstrip("\n")], text.count("\n"))
print("cols", open(f"{out}/vga.cols").read().strip())
EOF
base_a=$(python3 - "$BASE" <<'EOF'
import gzip, struct, sys
d = gzip.open(sys.argv[1]).read()
_, _, header, flags, count, size, _, _ = struct.unpack("<4sIIIIIII", d[:32])
for slot, entry in enumerate(d[header + count * size:].split(b"\xff")[:count]):
    if "A" in entry.decode("utf-8", "replace"):
        print(d[header + slot * size:header + (slot + 1) * size].hex()); break
EOF
)
grep -qx 'header 72b54a86 256 16 16 8 1' "$work/report" && ok "PSF2, 256 glyphs of 8x16, with a Unicode table" || fail "header: $(grep header "$work/report")"
grep -qx 'blocks 2588 2584 2580 kept' "$work/report" && ok "the full, lower and upper blocks keep their CP437 slots (0xDB, 0xDC, 0xDF)" || fail "blocks: $(grep blocks "$work/report")"
grep -qx 'cp437 kept' "$work/report" && ok "every slot but the pieces' keeps its CP437 character" || fail "cp437: $(grep cp437 "$work/report")"
grep -qx "A $base_a 65" "$work/report" && ok "ASCII from the base font at its own code" || fail "A: $(grep '^A ' "$work/report")"
grep -qx "piece0 c[0-9a-f] f0f0f0f0f0f0f0f0ffffffffffffffff" "$work/report" && ok "a piece running into the next cell: in 0xC0-0xDF, left column full, right its lower half" || fail "piece0: $(grep piece0 "$work/report")"
grep -qx "piece1 [0-9a-f]* 0000000000000000f0f0f0f0f0f0f0f0" "$work/report" && ok "a piece's bitmap: the left column's lower half" || fail "piece1: $(grep piece1 "$work/report")"
grep -qx "piece2 [0-9a-f]* f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0" "$work/report" && ok "a piece's bitmap: the left column full" || fail "piece2: $(grep piece2 "$work/report")"
grep -E '^piece[12] ' "$work/report" | grep -qE ' e[0-9a-f] ' && ok "pieces that end in their cell go to 0xE0 onwards" || fail "pieces that end in their cell: $(grep -E '^piece[12] ' "$work/report")"
grep -qx "text \['0xe000', '0xe001', '0xe002'\] 1" "$work/report" && ok "the text: three private-use characters on one line" || fail "text: $(grep text "$work/report")"
grep -qx 'cols 3' "$work/report" && ok "width 3 cells" || fail "cols: $(grep cols "$work/report")"

if [[ -r /usr/share/omarchy/logo.txt ]]; then
  python3 "$TOOL" /usr/share/omarchy/logo.txt "$BASE" "$work/real" 2>"$work/err-real" || fail "real logo: $(cat "$work/err-real")"
  if [[ $(cat "$work/real/vga.cols") == 41 && $(wc -l <"$work/real/vga.txt") == 5 ]]; then
    ok "the real logo: 41x5 cells"
  else
    fail "the real logo: $(cat "$work/real/vga.cols") columns, $(wc -l <"$work/real/vga.txt") rows"
  fi
else
  echo "skip: no /usr/share/omarchy/logo.txt here"
fi

printf '%s\n' 'OMARCHY' >"$work/letters.txt"
if python3 "$TOOL" "$work/letters.txt" "$BASE" "$work/letters" 2>/dev/null; then fail "a logo of letters was drawn"; else ok "refuses a logo with other glyphs than blocks"; fi
if [[ -r /usr/share/kbd/consolefonts/ter-v32b.psf.gz ]]; then
  if python3 "$TOOL" "$work/logo.txt" /usr/share/kbd/consolefonts/ter-v32b.psf.gz "$work/big" 2>/dev/null; then fail "a 16x32 base font was taken"; else ok "refuses a base font that is not 8x16"; fi
fi

exit "$((failures > 0))"
