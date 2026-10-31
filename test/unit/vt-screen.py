#!/usr/bin/env python3
"""vt-screen.py ROWS COLS [BEFORE] < output: the Linux VT's screen after the
output, one line a row (trailing blanks dropped). The VT starts showing
BEFORE's lines (a file), or blank; with BEFORE, a last line lists the cells
that show the same before and after but went blank in between ("flashed:
row,col ..." 1-based, or "flashed: none").

The part of the VT the console logo's layout uses: characters with autowrap
(the cursor stays on the last column until the next character), CR, LF, CUP,
CHA, ED, EL, ECH; SGR, DECTCEM and the palette's OSC P are read and ignored.
"""

import re
import sys

rows, cols = int(sys.argv[1]), int(sys.argv[2])
screen = [[" "] * cols for _ in range(rows)]
if len(sys.argv) > 3:
    for r, line in enumerate(open(sys.argv[3], encoding="utf-8").read().split("\n")[:rows]):
        for c, char in enumerate(line[:cols]):
            screen[r][c] = char
before = [row[:] for row in screen]
went_blank = set()
y = x = 0
wrap = False


def put(r, c, char):
    if char == " ":
        went_blank.add((r, c))
    screen[r][c] = char


def line_feed():
    global y
    if y == rows - 1:
        screen.pop(0)
        screen.append([" "] * cols)
        shifted = {(r - 1, c) for r, c in went_blank if r > 0}
        went_blank.clear()
        went_blank.update(shifted)
    else:
        y += 1


text = sys.stdin.read()
i = 0
while i < len(text):
    char = text[i]
    if char == "\033":
        m = re.compile(r"\[(\??)([0-9;]*)([A-Za-z])").match(text, i + 1)
        if m:
            private, params, final = m.groups()
            args = [int(p) if p else 0 for p in params.split(";")] if params else []
            arg = lambda n, default: args[n] if len(args) > n and args[n] else default
            if private:
                pass
            elif final in "Hf":
                y, x, wrap = min(arg(0, 1), rows) - 1, min(arg(1, 1), cols) - 1, False
            elif final == "G":
                x, wrap = min(arg(0, 1), cols) - 1, False
            elif final == "J":
                cells = {0: [(r, c) for r in range(rows) for c in range(cols) if (r, c) >= (y, x)],
                         1: [(r, c) for r in range(rows) for c in range(cols) if (r, c) <= (y, x)],
                         2: [(r, c) for r in range(rows) for c in range(cols)]}[args[0] if args else 0]
                for r, c in cells:
                    put(r, c, " ")
                wrap = False
            elif final == "K":
                span = {0: range(x, cols), 1: range(0, x + 1), 2: range(cols)}[args[0] if args else 0]
                for c in span:
                    put(y, c, " ")
                wrap = False
            elif final == "X":
                for c in range(x, min(cols, x + arg(0, 1))):
                    put(y, c, " ")
                wrap = False
            i = m.end()
            continue
        if text.startswith("]P", i + 1):
            i += 10
            continue
        raise SystemExit(f"vt-screen.py: unknown escape at {text[i:i + 12]!r}")
    if char == "\r":
        x, wrap = 0, False
    elif char == "\n":
        line_feed()
    else:
        if wrap:
            x, wrap = 0, False
            line_feed()
        put(y, x, char)
        if x == cols - 1:
            wrap = True
        else:
            x += 1
    i += 1

for row in screen:
    print("".join(row).rstrip())
if len(sys.argv) > 3:
    flashed = sorted((r, c) for r, c in went_blank if before[r][c] != " " and screen[r][c] == before[r][c])
    print("flashed: " + (" ".join(f"{r + 1},{c + 1}" for r, c in flashed) or "none"))
