#!/usr/bin/env python3
"""Generate the install snake; development only, no runtime dependencies.

Grid verified by 1/80 SVG raster and full-size cell-centre samples against
omacom/omarchy-site brand/omarchy-logo.svg, blob aa239e1f0402c3b22be01c9484f4eecedad2935e.
The mouth is (14, 8), not (14, 7); (13, 7) is not a dead end.
"""
from pathlib import Path

GRID = '''###############
#......#......#
#.######...##.#
#.#.........#.#
#.#.........#.#
#.#.........#.#
#.#.........#.#
###.........#.#
#.#.........#.#
#.#.........#.#
#.#.........#.#
#.#.........#.#
#.###########.#
#......#......#
########.######'''.splitlines()
OUTPUT = Path(__file__).resolve().parents[2] / 'configs/airootfs/usr/share/omarchy-iso/install-snake.path'


def generate():
    coarse = {(r, c) for r, row in enumerate(GRID) for c, v in enumerate(row) if v == '#'}
    assert len(coarse) == 95
    seen, tree = set(), []

    def visit(p, heading):
        seen.add(p)
        for dr, dc in [heading] + [d for d in [(0, 1), (1, 0), (0, -1), (-1, 0)] if d != heading]:
            q = p[0] + dr, p[1] + dc
            if q in coarse and q not in seen:
                tree.append((p, q))
                visit(q, (dr, dc))
    visit((13, 7), (-1, 0))
    assert seen == coarse and len(tree) == 94
    graph = {}

    def link(a, b):
        graph.setdefault(a, set()).add(b)
        graph.setdefault(b, set()).add(a)

    def unlink(a, b):
        graph[a].remove(b)
        graph[b].remove(a)

    for r, c in sorted(coarse):
        a, b, d, e = (2*r, 2*c), (2*r, 2*c+1), (2*r+1, 2*c+1), (2*r+1, 2*c)
        for x, y in [(a, b), (b, d), (d, e), (e, a)]:
            link(x, y)
    for p, q in tree:
        p, q = sorted((p, q))
        r, c = p[0]*2, p[1]*2
        if p[0] == q[0]:
            a, b, d, e = (r, c+1), (r+1, c+1), (r, c+2), (r+1, c+2)
        else:
            a, b, d, e = (r+1, c), (r+1, c+1), (r+2, c), (r+2, c+1)
        unlink(a, b)
        unlink(d, e)
        link(a, d)
        link(b, e)
    assert all(len(v) == 2 for v in graph.values())
    start = (27, 14)
    path = [start]
    previous, current = start, next(v for v in graph[start] if v[0] < start[0])
    while current != start:
        path.append(current)
        previous, current = current, next(v for v in graph[current] if v != previous)
        assert len(path) <= 380
    expected = {(2*r+dr, 2*c+dc) for r, c in coarse for dr in (0, 1) for dc in (0, 1)}
    assert len(path) == len(set(path)) == 380
    assert set(path) == expected
    assert all(abs(a[0]-b[0])+abs(a[1]-b[1]) == 1 for a, b in zip(path, path[1:]+path[:1]))
    return path


if __name__ == '__main__':
    path = generate()
    OUTPUT.write_text(''.join(f'{r} {c}\n' for r, c in path))
    print(f'Validated and wrote {len(path)} cells to {OUTPUT}')
