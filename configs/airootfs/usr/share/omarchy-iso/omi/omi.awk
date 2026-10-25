# Omi's player in awk, for omi.sh: it reads the Omi kit (flattened to tab-
# separated lines by jq, see omi.sh), then events on stdin, one a line:
#
#   tick <seconds>   draw a frame (seconds: the clock, or - for "about 1/30 s
#                    since the last one")
#   key <byte>       a byte the terminal sent: a key, or part of a mouse report
#   size <cols> <rows>
#
# and draws Omi with half-block characters on stdout. After each frame it
# writes a line to the file `ready`, so the clock only ticks as fast as
# frames are drawn. With -v once=<mode> it prints that mode at rest and ends.
# With -v rects=1 it reads "<mode> <seconds>" lines instead and prints the
# rects there (x, y, w, h, opacity, role, tab-separated, then a blank line),
# body motion on: tools/check-bash.js holds those to kit/conformance.json.
#
# With -v drive=1 another program drives it, a line at a time, and draws
# what it answers itself (the Omarchy installer's dashboard does):
#
#   size <px>        Omi's view this many pixels across (made crisp); answers
#                    "dims <cols> <rows> <center>", center: where the view's
#                    middle falls across those columns, in half columns
#   now <mode>       morph there now
#   next <mode>      morph there when the loop playing ends
#   tick <seconds>   the clock now (any that only goes up); answers
#                    "frame <mode> <morphing 0|1> <loops played>", then the
#                    rows of Omi, as many as dims said
#
# -v colors=16 draws in the terminal's own green and grey (SGR 32 and 90,
# faded pixels grey), for a console that has only its 16 colors. -v
# colors=shades draws faded pixels in more of those 16, for a console whose
# palette has been set to Omi's green faded into the background in them:
# then a fade looks like a fade. -v shades=<SGR,SGR,...> names them, from
# most opaque to least, evenly spaced (default 92,94,95,96: four shades). -v
# only=<mode,mode,...> crops the drawing to where those modes' pieces go,
# instead of the whole view with room for every mode.
#
# It follows kit/README.md: animations (rests, delays, eases, the body and
# a clip window), the gaze, the crisp sizes. The one thing it does its own
# way is the morph: pieces that stay put stay, the rest pair with their
# nearest partner in order, new ones split off or grow and old ones slide
# away or shrink, staggered from the center. The README allows that (only a
# morph's start and landing are fixed); it is simpler than the reference
# player's pairing, so some morphs look different, never wrong.
#
# Written for any POSIX awk (the one-true-awk on macOS, mawk, gawk).

BEGIN {
  FS = "\t"
  ESC = sprintf("%c", 27)
  load(kitfile)
  FACE["eye"] = FACE["brow"] = FACE["mouth"] = FACE["tear"] = 1
  bounce = bounce + 0
  if (fg != "") split(fg, FG, " ")
  if (bg != "") split(bg, BG, " ")
  if (only != "") { split(only, q, ","); for (i in q) ONLY[q[i]] = 1 }
  findReach()

  if (once != "") { still(once); exit }
  if (drive) { driven(); exit }
  if (rects) {
    bounce = 1; FS = " "
    while ((getline line) > 0) {
      split(line, E, " "); n = modeRects(E[1], E[2] + 0, CX, CY, CW, CH, CO, CR)
      for (i = 1; i <= n; i++) printf "%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%s\n", CX[i], CY[i], CW[i], CH[i], CO[i], CR[i]
      print ""
    }
    exit
  }

  cols = 80; rows = 24
  clock = 0; tAnim = 0; morphing = 0; curMode = "logo"; rc = 0
  GFX = GFY = GTX = GTY = 0; GP = 1
  touring = 1; next_i = 0; landedAt = -1; holdFor = 0
  poked = 0; pokes = 0; lastInput = 0; asleep = 0
  layout()
  printf "%s[2J", ESC
  startAt = 0.7 # the plain logo first, then Omi comes to life
  FS = " "
  while ((getline line) > 0) {
    n = split(line, E, " ")
    if (E[1] == "tick") tick(E[2])
    else if (E[1] == "key") byte(E[2] + 0)
    else if (E[1] == "size") { cols = E[2] + 0; rows = E[3] + 0; layout(); delete SHOWN; printf "%s[2J", ESC }
    if (quit) break
  }
  exit
}

# ------------------------------------------------------------------ the kit
function load(file,    line, f, n, k, a, i, m, c, j, props, q, ks, hasAny) {
  while ((getline line < file) > 0) {
    n = split(line, f, "\t")
    if (f[1] == "G") GRID = f[2] + 0
    else if (f[1] == "V") { VX = f[2]; VY = f[3]; VW = f[4]; VH = f[5] }
    else if (f[1] == "M") {
      MDUR = f[2]; MSTAG = f[3]; MEASE = f[4]; MCX = f[5]; MCY = f[6]
      SPLIT = f[7]; PEN = f[8]
    } else if (f[1] == "Z") {
      GAZE = 1; GRX = f[2]; GRY = f[3]; GDUR = f[4]; GEASE = f[5]
      GIX = f[6]; GIY = f[7]; GIW = f[8]; GIH = f[9]
      split(f[10], q, ","); for (k in q) GROLE[q[k]] = 1
    } else if (f[1] == "A") {
      a = f[2]; AD[a] = f[3]; AR[a] = f[4]; AE[a] = f[5]; AK[a] = 0
    } else if (f[1] == "K") {
      a = f[2]; k = f[3] + 1
      if (k > AK[a]) AK[a] = k
      KP[a, k] = f[4]; KV[a, k, f[5]] = f[6]; KS[a, k, f[5]] = 1
    } else if (f[1] == "O") {
      m = f[2]; NM++; MODE[NM] = m; MI[m] = NM
      MKIND[m] = f[3]; MHOLD[m] = f[4]; MNAME[m] = f[5]; MLABEL[m] = f[6]
      MGROUP[m] = f[7]; split(f[8], q, ","); MBX[m] = q[1]; MBY[m] = q[2]
      MBW[m] = q[3]; MBH[m] = q[4]; MANIM[m] = f[9]
      if (f[10] != "") {
        split(f[10], q, ","); MC[m] = 1
        MCX_[m] = q[1]; MCY_[m] = q[2]; MCW[m] = q[3]; MCH[m] = q[4]; MCA[m] = q[5]
      }
      PN[m] = 0
    } else if (f[1] == "P") {
      m = f[2]; i = ++PN[m]
      PX[m, i] = f[3]; PY[m, i] = f[4]; PW[m, i] = f[5]; PH[m, i] = f[6]
      PROLE[m, i] = f[7]; POP[m, i] = f[8]; PANIM[m, i] = f[9]
      PDEL[m, i] = f[10]; PDUR[m, i] = f[11]; PCLIP[m, i] = f[12]
      PVAR[m, i, "mx"] = f[13]; PVAR[m, i, "my"] = f[14]
      PVAR[m, i, "dx"] = f[15]; PVAR[m, i, "dy"] = f[16]
    }
  }
  close(file)
  CELLS = VW / GRID
  # Each animation's two channels, move (tx ty sx sy) and opacity (op): the
  # keys that set any of the channel's values, with rest keys added at 0
  # and 1 when the channel has none there.
  split("tx ty sx sy", CH1, " "); split("op", CH2, " ")
  for (a in AD) for (c = 1; c <= 2; c++) {
    ks = 0
    for (k = 1; k <= AK[a]; k++) {
      hasAny = 0
      if (c == 1) { for (j = 1; j <= 4; j++) if ((a, k, CH1[j]) in KS) hasAny = 1 }
      else if ((a, k, "op") in KS) hasAny = 1
      if (!hasAny) continue
      if (!ks && KP[a, k] > 0) { ks++; CKP[a, c, ks] = 0; CKI[a, c, ks] = 0 }
      ks++; CKP[a, c, ks] = KP[a, k]; CKI[a, c, ks] = k
    }
    if (ks && CKP[a, c, ks] < 1) { ks++; CKP[a, c, ks] = 1; CKI[a, c, ks] = 0 }
    CKN[a, c] = ks
  }
}

# ------------------------------------------------------------------ easing
function bez(e, p,    q, lo, hi, t, i) {
  if (e == "steps") return p >= 1 ? 1 : 0
  if (p <= 0 || p >= 1) return p
  split(e, q, ",")
  lo = 0; hi = 1; t = p
  for (i = 0; i < 24; i++) {
    t = (lo + hi) / 2
    if (B(q[1], q[3], t) < p) lo = t; else hi = t
  }
  return B(q[2], q[4], t)
}
function B(a, b, t) { return 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t }
function restOf(q) { return (q == "sx" || q == "sy" || q == "op") ? 1 : 0 }

# ------------------------------------------------------------------ animations
# How a piece looks t seconds into its animation a: sets L["tx"] … L["op"].
# m, i name the piece (for its delay, duration and numbers), or i = 0.
function look(a, t, m, i,    dur, r, cyc, u, p, c, ks, j, p0, p1, k0, k1, k, q, A_, B_, np, props) {
  L["tx"] = L["ty"] = 0; L["sx"] = L["sy"] = L["op"] = 1
  if (a == "" || !(a in AD)) return
  dur = (i && PDUR[m, i] != "") ? PDUR[m, i] : AD[a]
  r = AR[a]; cyc = r + dur
  u = (t - (i ? PDEL[m, i] : 0)) % cyc; if (u < 0) u += cyc
  p = u < r ? 0 : (u - r) / dur; if (p > 1) p = 1
  for (c = 1; c <= 2; c++) {
    ks = CKN[a, c]; if (!ks) continue
    j = 2
    while (j < ks && p > CKP[a, c, j]) j++
    p0 = CKP[a, c, j - 1]; p1 = CKP[a, c, j]
    k = (p1 == p0) ? 1 : bez(AE[a], (p - p0) / (p1 - p0))
    np = (c == 1) ? 4 : 1
    for (q = 1; q <= np; q++) {
      props = (c == 1) ? CH1[q] : "op"
      A_ = val(a, CKI[a, c, j - 1], props, m, i)
      B_ = val(a, CKI[a, c, j], props, m, i)
      L[props] = A_ + (B_ - A_) * k
    }
  }
}
# a key's value: a number, its rest, or a piece's own number times a factor
function val(a, k, q, m, i,    v, f) {
  if (!k || !((a, k, q) in KS)) return restOf(q)
  v = KV[a, k, q]
  if (substr(v, 1, 1) == "@") {
    split(substr(v, 2), f, "*")
    return (i ? PVAR[m, i, f[1]] : 0) * f[2]
  }
  return v + 0
}

# ------------------------------------------------------------------ rects
# The rects of mode m, t seconds into its loops, into X Y W H O R; returns
# how many. Only those with opacity above 0.001.
function modeRects(m, t, X, Y, W, H, O, R,    o, n, cx, cy, bsx, bsy, btx, bty, hasBody, ltx, lty, order, k, i, w, h, x, y, x2, y2) {
  n = 0
  hasBody = bounce && MANIM[m] != ""
  if (hasBody) { look(MANIM[m], t, m, 0); bsx = L["sx"]; bsy = L["sy"]; btx = L["tx"]; bty = L["ty"] }
  ltx = lty = 0
  if (MC[m] && MCA[m] != "") { look(MCA[m], t, m, 0); ltx = L["tx"]; lty = L["ty"] }
  cx = MBX[m] + MBW[m] / 2; cy = MBY[m] + MBH[m] / 2
  # pieces seen through the window first, then the rest
  k = 0
  if (MC[m]) {
    for (i = 1; i <= PN[m]; i++) if (PCLIP[m, i]) order[++k] = i
    for (i = 1; i <= PN[m]; i++) if (!PCLIP[m, i]) order[++k] = i
  } else for (i = 1; i <= PN[m]; i++) order[++k] = i
  for (k = 1; k <= PN[m]; k++) {
    i = order[k]
    look(PANIM[m, i], t, m, i)
    w = PW[m, i] * L["sx"]; h = PH[m, i] * L["sy"]
    x = PX[m, i] + PW[m, i] / 2 - w / 2 + L["tx"]
    y = PY[m, i] + PH[m, i] / 2 - h / 2 + L["ty"]
    o = POP[m, i] * L["op"]
    if (PCLIP[m, i] && MC[m]) {
      x += ltx; y += lty
      x2 = min(x + w, MCX_[m] + MCW[m]); y2 = min(y + h, MCY_[m] + MCH[m])
      x = max(x, MCX_[m]); y = max(y, MCY_[m])
      w = x2 - x; h = y2 - y
      if (w < 0.01 || h < 0.01) continue
    }
    if (hasBody) {
      x = cx + (x - cx) * bsx + btx; y = cy + (y - cy) * bsy + bty
      w *= bsx; h *= bsy
    }
    if (o <= 0.001) continue
    n++; X[n] = x; Y[n] = y; W[n] = w; H[n] = h; O[n] = o; R[n] = PROLE[m, i]
  }
  return n
}
function min(a, b) { return a < b ? a : b }
function max(a, b) { return a > b ? a : b }

# ------------------------------------------------------------------ morphs
# Change to mode m: a morph from whatever is on screen (or a jump).
function setMode(m, instant,    n, i, j, best, cost, c, dx, dy, nd, ns, dX, dY, dW, dH, dO, dR) {
  if (!(m in MI)) return
  if (m == curMode && !morphing) return
  current(SX, SY, SW, SH, SO, SR); ns = CN
  curMode = m
  if (instant || !ns) { morphing = 0; tAnim = 0; settled(); return }
  nd = modeRects(m, 0, dX, dY, dW, dH, dO, dR)
  delete SU; delete DU; NP = 0
  # 1. what stays where it is, stays
  for (j = 1; j <= nd; j++) for (i = 1; i <= ns; i++) {
    if (SU[i] || SR[i] != dR[j]) continue
    if (abs(SX[i] - dX[j]) < 0.5 && abs(SY[i] - dY[j]) < 0.5 && abs(SW[i] - dW[j]) < 0.5 && abs(SH[i] - dH[j]) < 0.5) {
      pair(SX[i], SY[i], SW[i], SH[i], SO[i], dX[j], dY[j], dW[j], dH[j], dO[j], dR[j], 1, 0)
      SU[i] = DU[j] = 1; break
    }
  }
  # 1b. what's already drawn, cut into other pieces, stays too: the logo is a
  # bar in one mode and tiles in another (for a sweep), the same pixels. A
  # piece the other side's pieces cover stays where it is and only fades
  # between their opacities, instead of sliding off to a partner.
  for (j = 1; j <= nd; j++) {
    if (DU[j] || !covered(dX[j], dY[j], dW[j], dH[j], dR[j], SX, SY, SW, SH, SR, ns)) continue
    pair(dX[j], dY[j], dW[j], dH[j], faintest(dX[j], dY[j], dW[j], dH[j], dR[j], SX, SY, SW, SH, SO, SR, ns),
      dX[j], dY[j], dW[j], dH[j], dO[j], dR[j], 1, 0)
    DU[j] = 1
  }
  for (i = 1; i <= ns; i++) {
    if (SU[i] || !covered(SX[i], SY[i], SW[i], SH[i], SR[i], dX, dY, dW, dH, dR, nd)) continue
    pair(SX[i], SY[i], SW[i], SH[i], SO[i], SX[i], SY[i], SW[i], SH[i],
      faintest(SX[i], SY[i], SW[i], SH[i], SR[i], dX, dY, dW, dH, dO, dR, nd), SR[i], 1, 0)
    SU[i] = 1
  }
  # 2. the rest, each new piece in order with its nearest old one
  for (j = 1; j <= nd; j++) {
    if (DU[j]) continue
    best = 0
    for (i = 1; i <= ns; i++) {
      if (SU[i] || banned(SR[i], dR[j])) continue
      c = dist2(SX[i], SY[i], SW[i], SH[i], dX[j], dY[j], dW[j], dH[j]) + 0.5 * ((SW[i] - dW[j]) ^ 2 + (SH[i] - dH[j]) ^ 2) + (SR[i] != dR[j] ? PEN * PEN : 0)
      if (!best || c < cost) { best = i; cost = c }
    }
    if (best) {
      i = best; SU[i] = DU[j] = 1
      pair(SX[i], SY[i], SW[i], SH[i], SO[i], dX[j], dY[j], dW[j], dH[j], dO[j], dR[j], 0, 0)
    }
  }
  # 3. new pieces left over split off their nearest old one, or grow
  for (j = 1; j <= nd; j++) {
    if (DU[j]) continue
    i = nearest(dX[j], dY[j], dW[j], dH[j], dR[j], SX, SY, SW, SH, SR, ns)
    if (i) pair(SX[i], SY[i], SW[i], SH[i], SO[i], dX[j], dY[j], dW[j], dH[j], dO[j], dR[j], 0, 0)
    else pair(dX[j] + dW[j] / 2, dY[j] + dH[j] / 2, 0, 0, 0, dX[j], dY[j], dW[j], dH[j], dO[j], dR[j], 0, 1)
  }
  # 4. old pieces left over slide into their nearest new one, or shrink
  for (i = 1; i <= ns; i++) {
    if (SU[i]) continue
    j = nearest(SX[i], SY[i], SW[i], SH[i], SR[i], dX, dY, dW, dH, dR, nd)
    if (j) pair(SX[i], SY[i], SW[i], SH[i], SO[i], dX[j], dY[j], dW[j], dH[j], 0, dR[j], 0, 0)
    else pair(SX[i], SY[i], SW[i], SH[i], SO[i], SX[i] + SW[i] / 2, SY[i] + SH[i] / 2, 0, 0, 0, SR[i], 0, 0)
  }
  morphing = 1; mT = 0
}
function abs(v) { return v < 0 ? -v : v }
# whether pieces of role r in a list cover a rect, checked every 5 units (half
# the kit's finest step; a piece caught mid-move never lines up, and moves)
function covered(x, y, w, h, r, X, Y, W, H, R, n,    a, b, px, py, i, in_) {
  if (w < 1 || h < 1) return 0
  for (a = 2.5; a < w; a += 5) for (b = 2.5; b < h; b += 5) {
    px = x + a; py = y + b; in_ = 0
    for (i = 1; i <= n; i++)
      if (R[i] == r && px > X[i] && px < X[i] + W[i] && py > Y[i] && py < Y[i] + H[i]) { in_ = 1; break }
    if (!in_) return 0
  }
  return 1
}
# the faintest opacity of the pieces of role r in a list that overlap a rect
function faintest(x, y, w, h, r, X, Y, W, H, O, R, n,    i, o) {
  o = 1
  for (i = 1; i <= n; i++)
    if (R[i] == r && X[i] < x + w && X[i] + W[i] > x && Y[i] < y + h && Y[i] + H[i] > y && O[i] < o) o = O[i]
  return o
}
function banned(a, b) { return (a == "frame" && (b in FACE)) || (b == "frame" && (a in FACE)) }
function dist2(x1, y1, w1, h1, x2, y2, w2, h2) {
  return (x1 + w1 / 2 - x2 - w2 / 2) ^ 2 + (y1 + h1 / 2 - y2 - h2 / 2) ^ 2
}
# the nearest of a list within the split reach, for a piece of role r
function nearest(x, y, w, h, r, X, Y, W, H, R, n,    i, best, bestC, c, d) {
  best = 0
  for (i = 1; i <= n; i++) {
    if (banned(r, R[i])) continue
    d = dist2(x, y, w, h, X[i], Y[i], W[i], H[i])
    if (d >= SPLIT * SPLIT) continue
    c = d + (R[i] != r ? PEN * PEN : 0)
    if (!best || c < bestC) { best = i; bestC = c }
  }
  return best
}
# One piece of a morph, from one rect to another, starting late by its
# distance from the center (a piece that stays: a quarter of the stagger).
function pair(fx, fy, fw, fh, fo, tx, ty, tw, th, to, r, rigid, grow,    cx, cy, d) {
  NP++
  FX[NP] = fx; FY[NP] = fy; FW[NP] = fw; FH[NP] = fh; FO[NP] = fo
  TX[NP] = tx; TY[NP] = ty; TW[NP] = tw; TH[NP] = th; TO[NP] = to
  PRL[NP] = r; PGR[NP] = grow
  if (rigid) PDL[NP] = MSTAG / 4
  else {
    cx = (tw || th) ? tx + tw / 2 : fx + fw / 2; cy = (tw || th) ? ty + th / 2 : fy + fh / 2
    d = sqrt((cx - MCX) ^ 2 + (cy - MCY) ^ 2) / 260
    PDL[NP] = (d > 1 ? 1 : d) * MSTAG
  }
}
function morphRects(X, Y, W, H, O, R,    n, i, p, e, s, cx, cy) {
  n = 0
  for (i = 1; i <= NP; i++) {
    p = (mT - PDL[i]) / MDUR; p = p < 0 ? 0 : p > 1 ? 1 : p
    if (PGR[i]) {
      # grow from its own center, a little past its size and back
      s = p >= 1 ? 1 : 1 + 2.70158 * (p - 1) ^ 3 + 1.70158 * (p - 1) ^ 2
      cx = TX[i] + TW[i] / 2; cy = TY[i] + TH[i] / 2
      n++; W[n] = TW[i] * s; H[n] = TH[i] * s; X[n] = cx - W[n] / 2; Y[n] = cy - H[n] / 2
      O[n] = TO[i] * (3 * p < 1 ? 3 * p : 1)
    } else {
      e = bez(MEASE, p)
      n++; X[n] = FX[i] + (TX[i] - FX[i]) * e; Y[n] = FY[i] + (TY[i] - FY[i]) * e
      W[n] = FW[i] + (TW[i] - FW[i]) * e; H[n] = FH[i] + (TH[i] - FH[i]) * e
      O[n] = FO[i] + (TO[i] - FO[i]) * e
    }
    R[n] = PRL[i]
    if (O[n] <= 0.001 || W[n] <= 0 || H[n] <= 0) n--
  }
  return n
}
# What is on screen now, before the gaze, into X …: sets CN.
function current(X, Y, W, H, O, R) {
  CN = morphing ? morphRects(X, Y, W, H, O, R) : modeRects(curMode, tAnim, X, Y, W, H, O, R)
}

# ------------------------------------------------------------------ the gaze
function lookTo(dx, dy) {
  if (!GAZE) return
  dx = dx < -1 ? -1 : dx > 1 ? 1 : dx; dy = dy < -1 ? -1 : dy > 1 ? 1 : dy
  if (dx == GTX && dy == GTY) return
  gazeNow(); GFX = GNX; GFY = GNY; GTX = dx; GTY = dy; GP = 0
}
function gazeNow(   e) {
  if (GP >= 1) { GNX = GTX; GNY = GTY; return }
  e = bez(GEASE, GP); GNX = GFX + (GTX - GFX) * e; GNY = GFY + (GTY - GFY) * e
}
# move the eyes by the gaze, kept inside the box
function withGaze(X, Y, W, H, R, n,    i, dx, dy) {
  if (!GAZE) return
  gazeNow()
  if (!GNX && !GNY) return
  dx = room(GNX * GRX, GIX, GIX + GIW, X, W, R, n)
  dy = room(GNY * GRY, GIY, GIY + GIH, Y, H, R, n)
  for (i = 1; i <= n; i++) if (R[i] in GROLE) { X[i] += dx; Y[i] += dy }
}
function room(d, lo, hi, A, S, R, n,    i, mn, mx, any) {
  any = 0
  for (i = 1; i <= n; i++) {
    if (!(R[i] in GROLE) || A[i] < lo || A[i] + S[i] > hi) continue
    if (!any || lo - A[i] > mn) mn = lo - A[i]
    if (!any || hi - (A[i] + S[i]) < mx) mx = hi - (A[i] + S[i])
    any = 1
  }
  if (!any) return d
  if (mn > mx) return 0
  return d < mn ? mn : d > mx ? mx : d
}

# ------------------------------------------------------------------ timing
function loopSeconds(m,    t, i, d) {
  t = 0
  if (bounce && MANIM[m] != "") t = max(t, AR[MANIM[m]] + AD[MANIM[m]])
  if (MC[m] && MCA[m] != "") t = max(t, AR[MCA[m]] + AD[MCA[m]])
  for (i = 1; i <= PN[m]; i++) if (PANIM[m, i] != "") {
    d = PDUR[m, i] != "" ? PDUR[m, i] : AD[PANIM[m, i]]
    t = max(t, AR[PANIM[m, i]] + d + PDEL[m, i])
  }
  return t
}
function holdOf(m,    l) {
  if (MHOLD[m] != "") return MHOLD[m]
  l = loopSeconds(m); return l < 1.2 ? 1.2 : l > 2.5 ? 2.5 : l
}
function settled() { landedAt = clock }

# ------------------------------------------------------------------ drawing
# How far pieces reach past the view: from each piece's animation, its
# farthest move and largest scale, and the body's on top. Wider than the
# truth at times, never narrower, so nothing is cut off.
function findReach(    m, i, a, x0, y0, x1, y1, ex, ey, cx, cy, s, k) {
  RX0 = VX; RY0 = VY; RX1 = VX + VW; RY1 = VY + VH
  if (only != "") { RX0 = RY0 = 1e9; RX1 = RY1 = -1e9 }
  for (k = 1; k <= NM; k++) {
    m = MODE[k]
    if (only != "" && !(m in ONLY)) continue
    for (i = 1; i <= PN[m]; i++) {
      animBox(PANIM[m, i], m, i)
      ex = PW[m, i] * (ASX - 1) / 2; ey = PH[m, i] * (ASY - 1) / 2
      x0 = PX[m, i] - ex + ATX0; x1 = PX[m, i] + PW[m, i] + ex + ATX1
      y0 = PY[m, i] - ey + ATY0; y1 = PY[m, i] + PH[m, i] + ey + ATY1
      if (PCLIP[m, i] && MC[m]) {
        x0 = max(x0, MCX_[m]); y0 = max(y0, MCY_[m])
        x1 = min(x1, MCX_[m] + MCW[m]); y1 = min(y1, MCY_[m] + MCH[m])
      }
      if (MANIM[m] != "") {
        animBox(MANIM[m], m, 0); cx = MBX[m] + MBW[m] / 2; cy = MBY[m] + MBH[m] / 2
        x0 = cx + (x0 - cx) * ASX + ATX0; x1 = cx + (x1 - cx) * ASX + ATX1
        y0 = cy + (y0 - cy) * ASY + ATY0; y1 = cy + (y1 - cy) * ASY + ATY1
      }
      RX0 = min(RX0, x0); RY0 = min(RY0, y0); RX1 = max(RX1, x1); RY1 = max(RY1, y1)
    }
  }
}
# the range of an animation's moves and its largest scale, for a piece
function animBox(a, m, i,    k, v) {
  ATX0 = ATX1 = ATY0 = ATY1 = 0; ASX = ASY = 1
  if (a == "" || !(a in AD)) return
  for (k = 1; k <= AK[a]; k++) {
    if ((a, k, "tx") in KS) { v = val(a, k, "tx", m, i); ATX0 = min(ATX0, v); ATX1 = max(ATX1, v) }
    if ((a, k, "ty") in KS) { v = val(a, k, "ty", m, i); ATY0 = min(ATY0, v); ATY1 = max(ATY1, v) }
    if ((a, k, "sx") in KS) ASX = max(ASX, val(a, k, "sx", m, i))
    if ((a, k, "sy") in KS) ASY = max(ASY, val(a, k, "sy", m, i))
  }
}
# Where Omi is drawn at a size (the view's width in pixels): the view, and
# whole logo cells around it out to the reach, so Omi stays crisp. Sets
# AS (pixels a unit), AX AY (the unit at pixel 0), AW AH, ACX ACY (the
# view's center, in pixels).
function area(size,    cell, l, t, r, b, x0, y0) {
  if (only != "") {
    # just the reach, out to whole logo cells on the logo's own grid (the
    # view's corner is half a cell off it), and rows from an even cell, so
    # at an even number of pixels a cell, a cell's top is a row's top and
    # each block is drawn as whole characters, not halves of two rows
    AS = size / VW
    x0 = floorTo(RX0, GRID); y0 = floorTo(RY0, 2 * GRID)
    AW = rnd((cellUp(RX1) * GRID - x0) * AS)
    AH = rnd((cellUp(RY1) * GRID - y0) * AS); if (AH % 2) AH++
    AX = x0; AY = y0
    ACX = (VX + VW / 2 - AX) * AS; ACY = (VY + VH / 2 - AY) * AS
    return
  }
  AS = size / VW; cell = size / CELLS
  l = padTo(VX - RX0, cell); t = padTo(VY - RY0, cell)
  r = padTo(RX1 - VX - VW, cell); b = padTo(RY1 - VY - VH, cell)
  AW = l + size + r; AH = t + size + b; if (AH % 2) AH++
  AX = VX - l / AS; AY = VY - t / AS
  ACX = l + size / 2; ACY = t + size / 2
}
function floorTo(u, step,    c) { c = int(u / step); if (c * step > u) c--; return c * step }
function cellUp(u,    c) { c = u / GRID; return c == int(c) ? c : (c > 0 ? int(c) + 1 : int(c)) }
function padTo(units, cell,    p) {
  p = units * AS / cell; if (p <= 1e-9) return 0
  return (p == int(p) ? p : int(p) + 1) * cell
}
# rects to pixels, edges snapped: a pixel is as opaque as the rect over it
function pixels(X, Y, W, H, O, n,    i, x0, y0, x1, y1, x, y, o) {
  delete ON
  for (i = 1; i <= n; i++) {
    x0 = rnd((X[i] - AX) * AS); y0 = rnd((Y[i] - AY) * AS)
    x1 = rnd((X[i] + W[i] - AX) * AS); y1 = rnd((Y[i] + H[i] - AY) * AS)
    x0 = max(0, x0); y0 = max(0, y0); x1 = min(AW, x1); y1 = min(AH, y1)
    o = O[i] > 1 ? 1 : O[i]
    for (y = y0; y < y1; y++) for (x = x0; x < x1; x++)
      if (!((y * AW + x) in ON) || ON[y * AW + x] < o) ON[y * AW + x] = o
  }
}
function rnd(v) { return v < 0 ? -int(-v + 0.5) : int(v + 0.5) }
# a pixel's color: "" empty, "fg" Omi, or "r;g;b" faded into the background
function color(a,    lv) {
  if (colors == 16) return a >= 0.75 ? "fg" : a >= 0.25 ? "dim" : ""
  if (colors == "shades") {
    # n shades between empty and Omi's color, evenly spaced
    if (!NSH) NSH = split(shades == "" ? "92,94,95,96" : shades, SHADE, ",")
    lv = int(a * (NSH + 1) + 0.5)
    return lv >= NSH + 1 ? "fg" : lv <= 0 ? "" : "s" SHADE[NSH + 1 - lv]
  }
  if (a < 0.02) return ""
  if (a > 0.98 || bg == "") return a >= 0.5 ? "fg" : ""
  return int(BG[1] + (FG[1] - BG[1]) * a + 0.5) ";" int(BG[2] + (FG[2] - BG[2]) * a + 0.5) ";" int(BG[3] + (FG[3] - BG[3]) * a + 0.5)
}
function sgr(c, layer) {
  if (c == "") return layer == 38 ? "39" : "49"
  if ((colors == 16 || colors == "shades") && c == "fg") return layer == 38 ? "32" : "42"
  if (colors == "shades" && substr(c, 1, 1) == "s") return layer == 38 ? substr(c, 2) : substr(c, 2) + 10
  if (colors == 16 && c == "dim") return layer == 38 ? "90" : "100"
  if (c == "fg") return fg != "" ? layer ";2;" FG[1] ";" FG[2] ";" FG[3] : (layer == 38 ? "39" : "7")
  return layer ";2;" c
}
# A bright one of the 16 colors (SGR 90-97). The Linux console has only
# the eight dark ones as backgrounds: a bright background (100-107) shows as
# its dark twin, a different color altogether.
function bright(c) { return (colors == 16 || colors == "shades") && sgr(c, 38) + 0 >= 90 }
# how opaque a color is, in steps: 0 empty, the most for Omi's own
function level(c,    i) {
  if (c == "") return 0
  if (colors == 16) return c == "fg" ? 2 : 1
  if (c == "fg") return NSH + 1
  for (i = 1; i <= NSH; i++) if ("s" SHADE[i] == c) return NSH + 1 - i
}
# the dark color (one that can be a background) nearest to c
function darkest(c,    best, i, s) {
  best = level(c) <= level("fg") - level(c) ? "" : "fg"
  if (colors == "shades") for (i = 1; i <= NSH; i++) {
    s = "s" SHADE[i]
    if (!bright(s) && apart(s, c) < apart(best, c)) best = s
  }
  return best
}
function apart(a, b) { a = level(a) - level(b); return a < 0 ? -a : a }
# One row of characters: ▀ with the top pixel's color as foreground and the
# bottom's as background (or ▄ the other way round, so a bright color is
# never the background); escape codes only when a color changes.
function row(y,    s, last, x, top, bot, ch, code) {
  s = ""; last = ""
  for (x = 0; x < AW; x++) {
    top = ((y * AW + x) in ON) ? color(ON[y * AW + x]) : ""
    bot = (((y + 1) * AW + x) in ON) ? color(ON[(y + 1) * AW + x]) : ""
    # two bright colors in a cell: the fainter takes its nearest dark one
    if (top != bot && bright(top) && bright(bot)) {
      if (level(top) < level(bot)) top = darkest(top); else bot = darkest(bot)
    }
    if (top == "" && bot == "") { ch = " "; code = ESC "[39;49m" }
    else if (top == bot) { ch = "█"; code = ESC "[" sgr(top, 38) ";49m" }
    else if (bot == "") { ch = "▀"; code = ESC "[" sgr(top, 38) ";49m" }
    else if (top == "") { ch = "▄"; code = ESC "[" sgr(bot, 38) ";49m" }
    else if (bright(bot)) { ch = "▄"; code = ESC "[" sgr(bot, 38) ";" sgr(top, 48) "m" }
    else { ch = "▀"; code = ESC "[" sgr(top, 38) ";" sgr(bot, 48) "m" }
    if (code != last) { s = s code; last = code }
    s = s ch
  }
  return s ESC "[0m"
}
function ink(s) { return ESC "[1;" sgr("fg", 38) "m" s ESC "[0m" }
function dim(s) { return ESC "[2m" s ESC "[0m" }

# ------------------------------------------------------------------ --once
function still(m,    n, y, lines, k, first, last, i) {
  if (!(m in MI)) { print "No mode \"" m "\"." > "/dev/stderr"; exit 1 }
  area(crisp(size ? size : 44))
  n = modeRects(m, 0, CX, CY, CW, CH, CO, CR)
  pixels(CX, CY, CW, CH, CO, n)
  k = 0
  for (y = 0; y < AH; y += 2) lines[++k] = row(y)
  first = 1; last = k
  while (first < last && blank(lines[first])) first++
  while (last > first && blank(lines[last])) last--
  for (i = first; i <= last; i++) print lines[i]
}
function blank(s) { gsub(ESC "\\[[0-9;]*m", "", s); return s ~ /^ *$/ }
function crisp(n) { n = int(n / CELLS) * CELLS; return n < CELLS ? CELLS : n }

# ------------------------------------------------------------------ driven
# Another program's commands on stdin, Omi's rows on stdout (see the top).
function driven(    line, E, n, at, dt, prev, L, y, out) {
  FS = " "; curMode = "logo"; tAnim = 0; morphing = 0; lastAt = ""
  GFX = GFY = GTX = GTY = 0; GP = 1
  area(crisp(88))
  while ((getline line) > 0) {
    split(line, E, " ")
    if (E[1] == "size") {
      area(crisp(E[2] + 0)); printf "dims %d %d %d\n", AW, AH / 2, rnd(2 * ACX); fflush()
    } else if (E[1] == "now") { PENDING = ""; setMode(E[2]) }
    else if (E[1] == "next") {
      PENDING = (E[2] == curMode && !morphing) ? "" : E[2]
      # a loop that ended a moment ago counts as ending now
      L = loopSeconds(curMode)
      if (PENDING != "" && !morphing && (L == 0 || tAnim - int(tAnim / L) * L < 0.25)) {
        setMode(PENDING); PENDING = ""
      }
    }
    else if (E[1] == "tick") {
      at = E[2] + 0
      dt = lastAt == "" ? 0 : at - lastAt; lastAt = at
      dt = dt < 0 ? 0 : dt > 0.1 ? 0.1 : dt
      prev = tAnim
      if (morphing) { mT += dt; if (mT >= MDUR + MSTAG) { morphing = 0; tAnim = 0; prev = 0 } }
      else tAnim += dt
      L = loopSeconds(curMode)
      # a mode asked for next starts when the loop playing ends
      if (PENDING != "" && !morphing && (L == 0 || int(tAnim / L) > int(prev / L))) {
        setMode(PENDING); PENDING = ""; L = loopSeconds(curMode)
      }
      current(CX, CY, CW, CH, CO, CR)
      pixels(CX, CY, CW, CH, CO, CN)
      out = sprintf("frame %s %d %d\n", curMode, morphing ? 1 : 0, (L && !morphing) ? int(tAnim / L) : 0)
      for (y = 0; y < AH; y += 2) out = out row(y) "\n"
      printf "%s", out; fflush()
    }
  }
}

# ------------------------------------------------------------------ live
function layout(    s) {
  s = crisp(size ? size : 88); area(s)
  while (!size && s > CELLS && (AW > cols - 2 || AH / 2 > rows - 5)) { s -= CELLS; area(s) }
  OX = int((cols - AW) / 2) + 1; if (OX < 1) OX = 1
  OY = int((rows - AH / 2 - 5) / 2) + 1; if (OY < 1) OY = 1
}
function tick(at,    dt, n, y, i, k, out, nm, lb, h) {
  # never backwards, never a big jump; without a clock, about 1/30 s
  if (at == "-") dt = 1 / 30
  else { dt = lastAt == "" ? 0 : at - lastAt; lastAt = at }
  dt = dt < 0 ? 0 : dt > 0.1 ? 0.1 : dt
  clock += dt
  if (morphing) {
    mT += dt
    if (mT >= MDUR + MSTAG) { morphing = 0; tAnim = 0; settled() }
  } else tAnim += dt
  if (GP < 1) { GP += dt / GDUR; if (GP > 1) GP = 1 }
  if (lookUntil && clock > lookUntil) { lookUntil = 0; lookTo(0, 0) }

  # what Omi is doing: the entrance, the tour, a reaction, sleep
  if (startAt && clock >= startAt) { startAt = 0; go(MODE[nextMode()]) }
  if (poked && clock >= poked) { poked = 0; setMode(chosen) }
  if (!startAt && !poked && !asleep) {
    if (touring && landedAt >= 0 && !morphing && clock - landedAt >= holdFor) go(MODE[nextMode()])
    else if (!touring && clock - lastInput > 60) { asleep = 1; setMode("sleeping") }
  }

  current(CX, CY, CW, CH, CO, CR); n = CN
  withGaze(CX, CY, CW, CH, CR, n)
  pixels(CX, CY, CW, CH, CO, n)
  k = 0
  for (y = 0; y < AH; y += 2) LINE[++k] = sprintf("%" (OX - 1) "s", "") row(y)
  nm = MNAME[curMode]; lb = MLABEL[curMode]
  LINE[++k] = ""
  LINE[++k] = center(ink(nm), length(nm))
  LINE[++k] = center(dim(lb), length(lb))
  LINE[++k] = ""
  h = "← → modes   space react   b bounce " (bounce ? "off" : "on") "   t tour " (touring ? "off" : "on") "   q quit"
  if (length(h) > cols - 2) h = "← →  space  b  t  q"
  LINE[++k] = center(dim(h), length(h))
  out = ""
  for (i = 1; i <= k; i++) if (SHOWN[i] != LINE[i]) {
    out = out ESC "[" (OY + i - 1) ";1H" ESC "[2K" LINE[i]
    SHOWN[i] = LINE[i]
  }
  if (out != "") { printf "%s", out; fflush() }
  print "" > ready; fflush(ready)
}
function center(s, w,    p) { p = int((cols - w) / 2); return (p > 0 ? sprintf("%" p "s", "") : "") s }
function nextMode(    i) {
  # the modes the tour visits: every one but the plain logo
  do { next_i = next_i % NM + 1 } while (MODE[next_i] == "logo")
  return next_i
}
function go(m) {
  chosen = m; poked = 0
  setMode(m)
  landedAt = morphing ? -1 : clock
  holdFor = max(2.5, loopSeconds(m))
}
function step(by,    i) {
  touring = 0
  i = MI[chosen]
  do { i = (i - 1 + by + NM) % NM + 1 } while (MODE[i] == "logo")
  next_i = i; go(MODE[i])
}
function poke(    i, m, k) {
  # the reactions, in turn
  k = 0
  for (i = 1; i <= NM; i++) if (MKIND[MODE[i]] == "reaction") REACT[++k] = MODE[i]
  if (!k) return
  m = REACT[pokes++ % k + 1]
  setMode(m)
  poked = clock + MDUR + MSTAG + holdOf(m)
}
function touched() {
  lastInput = clock
  if (asleep) { asleep = 0; setMode(chosen) }
}

# ------------------------------------------------------------------ input
# Bytes from the terminal, one at a time: keys, and the mouse as SGR
# reports (ESC [ < button ; col ; row M), which turn the eyes and, on a
# click on Omi, play a reaction.
function byte(b,    c, s, f, q) {
  if (!b) return
  IN = IN sprintf("%c", b)
  while (IN != "") {
    if (substr(IN, 1, 1) != ESC) { c = substr(IN, 1, 1); IN = substr(IN, 2); keyIn(c); continue }
    if (length(IN) < 2) return
    if (substr(IN, 2, 1) != "[") { IN = substr(IN, 2); continue }
    if (!match(IN, /^.\[[<?0-9;]*[@-~]/)) {
      if (length(IN) > 32) IN = ""
      return
    }
    s = substr(IN, 3, RLENGTH - 2); IN = substr(IN, RLENGTH + 1)
    f = substr(s, length(s), 1); s = substr(s, 1, length(s) - 1)
    if (substr(s, 1, 1) == "<" && (f == "M" || f == "m")) {
      split(substr(s, 2), q, ";"); mouse(q[1] + 0, q[2] + 0, q[3] + 0, f == "M")
    } else if (f == "C") { touched(); step(1) }
    else if (f == "D") { touched(); step(-1) }
    else if (f == "O") lookTo(0, 0) # the terminal lost focus
  }
}
function keyIn(c) {
  if (c == "q" || c == "Q") { quit = 1; return }
  touched()
  if (c == " " || c == "\n" || c == "\r") poke()
  else if (c == "b") bounce = !bounce
  else if (c == "t") touring = !touring
}
function mouse(b, col, row, press,    dx, dy, far) {
  touched()
  dx = col - (OX + ACX); dy = (row - (OY + ACY / 2)) * 2 # a row is two pixels
  far = AS * VW * 1.2 # full tilt this far from Omi's center
  lookTo(dx / far, dy / far); lookUntil = clock + 2.5
  if (press && b % 4 == 0 && int(b / 32) % 2 == 0 && int(b / 64) % 2 == 0 &&
      col >= OX && col < OX + AW && row >= OY && row < OY + AH / 2) poke()
}
