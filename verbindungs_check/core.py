#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Verbindungs-Check Kern: Analyse von Track-Endpunkten + Fix-Berechnung + HTML.

Logik (unveraendert gegenueber der urspruenglichen Excel-Version):
- Jede Zeile/jeder Track ist eine Linie mit zwei Endpunkten (X1,Y1) und (X2,Y2).
- Gruppiert wird nach (Layer, Net). Alle Checks laufen nur innerhalb einer Gruppe.
- Endpunkte, die exakt aufeinanderliegen (aus verschiedenen Tracks), gelten als
  verbunden ("Partner") und sind ok.
- Zwei partnerlose Punkte, die naeher beieinander liegen als ihre Breite (Width),
  sollten eigentlich aufeinanderliegen -> FEHLER.

Neu:
- compute_fix(): berechnet, wohin die beiden falsch platzierten Endpunkte
  gesetzt werden muessen (Schnittpunkt / Mittelpunkt / unloesbar).
- build_html(): Report mit optionalen Fix-Buttons (Server-Modus) und
  markiertem Zielpunkt in der Zoom-Grafik.

Reine Standardbibliothek.
"""

import math
import html as htmllib
from collections import defaultdict


# ============================ Konfiguration ============================
# Zwei Punkte gelten als "gleiche Stelle" (verbunden), wenn ihr Abstand
# kleiner/gleich dieser Toleranz ist.
SNAP_TOLERANCE = 0.01   # mm

# Zwei Bahnen gelten als kollinear, wenn ihr Winkel hoechstens so gross ist.
ANGLE_TOL_DEG = 8.0

# Anzeige-Genauigkeit der Koordinaten im Report (rein kosmetisch).
ROUND_DECIMALS = 3

# Nur Tracks werten (Object Kind == "Track"). Fuer den Excel-Filter relevant.
FILTER_KIND = "Track"

# Spalten-Schluesselwoerter (nur fuer den Excel-Modus, Gross/Klein egal).
COL_HINTS = {
    "kind":  ["object kind", "object", "kind"],
    "layer": ["layer"],
    "net":   ["net"],
    "x1":    ["x1"],
    "y1":    ["y1"],
    "x2":    ["x2"],
    "y2":    ["y2"],
    "width": ["width", "breite"],
}
# ======================================================================


def to_float(val):
    """Wandelt einen Zellwert robust in float. Versteht deutsche Zahlen (Komma)."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        f = float(val)
        return None if math.isnan(f) else f
    s = str(val).strip()
    if s == "" or s.lower() in ("nan", "none"):
        return None
    if "," in s and "." in s:
        s = s.replace(".", "").replace(",", ".")
    elif "," in s:
        s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def find_column(columns, hints):
    """Findet eine Spalte anhand von Schluesselwoertern (exakt > startswith > enthaelt)."""
    low = {c: str(c).strip().lower() for c in columns}
    for hint in hints:
        for c in columns:
            if low[c] == hint:
                return c
    for hint in hints:
        for c in columns:
            if low[c].startswith(hint):
                return c
    for hint in hints:
        for c in columns:
            if hint in low[c]:
                return c
    return None


# ----------------------------- Analyse --------------------------------
#
# Punkt-Tupel:  (track_id, x, y, width, other_x, other_y, end)
#   track_id  - identifiziert den Track; zwei Endpunkte desselben Tracks teilen
#               sich die ID -> "gleiche Zeile" wird korrekt ignoriert.
#   end       - 1 oder 2: welcher Endpunkt des Tracks (fuer das Fix-Kommando).
#
def _build_grid(points, cell):
    grid = defaultdict(list)
    for idx, p in enumerate(points):
        cx = int(math.floor(p[1] / cell))
        cy = int(math.floor(p[2] / cell))
        grid[(cx, cy)].append(idx)
    return grid


def _neighbors(grid, cx, cy):
    out = []
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            out.extend(grid.get((cx + dx, cy + dy), ()))
    return out


def process_group(points):
    """
    points: Liste von Punkt-Tupeln einer Gruppe.
    Rueckgabe: (singles, errors)
      singles: partnerlose Punkte
      errors:  Naeherungs-Fehler als (pa, pb, dist, thr)
    """
    n = len(points)

    # --- Schritt 1: Partner-Erkennung ueber Abstand (Toleranz) ---
    paired = [False] * n
    if n >= 2:
        cell = SNAP_TOLERANCE if SNAP_TOLERANCE > 0 else 0.001
        grid = _build_grid(points, cell)
        for (cx, cy), idxs in grid.items():
            cand = _neighbors(grid, cx, cy)
            for a in idxs:
                if paired[a]:
                    continue
                pa = points[a]
                for b in cand:
                    if b == a:
                        continue
                    pb = points[b]
                    if pa[0] == pb[0]:
                        continue  # gleicher Track zaehlt nicht als Partner
                    dist = math.hypot(pa[1] - pb[1], pa[2] - pb[2])
                    if dist <= SNAP_TOLERANCE:
                        paired[a] = True
                        break

    unpaired = [points[i] for i in range(n) if not paired[i]]

    # --- Schritt 2: Naeherungs-Check zwischen partnerlosen Punkten ---
    errors = []
    if len(unpaired) >= 2:
        maxw = max((p[3] for p in unpaired), default=0.0)
        cell = maxw if maxw > 0 else 0.001
        grid = _build_grid(unpaired, cell)
        for (cx, cy), idxs in grid.items():
            cand = _neighbors(grid, cx, cy)
            for a in idxs:
                pa = unpaired[a]
                for b in cand:
                    if b <= a:
                        continue
                    pb = unpaired[b]
                    if pa[0] == pb[0]:
                        continue
                    thr = max(pa[3], pb[3])
                    if thr <= 0:
                        continue
                    dist = math.hypot(pa[1] - pb[1], pa[2] - pb[2])
                    if dist <= SNAP_TOLERANCE:
                        continue
                    if dist <= thr:
                        errors.append((pa, pb, dist, thr))

    return unpaired, errors


def _unit(dx, dy):
    L = math.hypot(dx, dy)
    if L == 0:
        return (0.0, 0.0), 0.0
    return (dx / L, dy / L), L


def circle_overlap_pct(d, rA, rB):
    """Ueberlappung zweier Kreise in Prozent (bezogen auf den kleineren)."""
    if rA <= 0 or rB <= 0:
        return 0.0
    if d >= rA + rB:
        return 0.0
    rmin = min(rA, rB)
    if d <= abs(rA - rB):
        return 100.0
    a = rA * rA * math.acos((d * d + rA * rA - rB * rB) / (2 * d * rA))
    b = rB * rB * math.acos((d * d + rB * rB - rA * rA) / (2 * d * rB))
    c = 0.5 * math.sqrt(max(0.0, (-d + rA + rB) * (d + rA - rB) *
                            (d - rA + rB) * (d + rA + rB)))
    lens = a + b - c
    return lens / (math.pi * rmin * rmin) * 100.0


def analyze_pair(pa, pb):
    """Geometrie zweier partnerloser Endpunkte (inkl. Bahnrichtung)."""
    ax, ay = pa[1], pa[2]
    bx, by = pb[1], pb[2]
    uA, _ = _unit(pa[4] - ax, pa[5] - ay)
    uB, _ = _unit(pb[4] - bx, pb[5] - by)

    gx, gy = bx - ax, by - ay
    dist = math.hypot(gx, gy)

    Wa, Wb = pa[3], pb[3]

    dot = uA[0] * uB[0] + uA[1] * uB[1]
    dotc = max(-1.0, min(1.0, dot))
    angle = math.degrees(math.acos(abs(dotc)))
    continuation = dot < 0

    gpar = gx * uA[0] + gy * uA[1]
    gperp = gx * (-uA[1]) + gy * uA[0]
    lat = abs(gperp)
    sep = -gpar

    overlap = circle_overlap_pct(dist, Wa / 2.0, Wb / 2.0)

    collinear = angle <= ANGLE_TOL_DEG
    is_overlap = collinear and continuation and sep < -SNAP_TOLERANCE and overlap > 0.0

    if is_overlap:
        category = "overlap"
        kind = "positive Ueberlappung (Bahnen laufen ineinander)"
    elif collinear and sep > SNAP_TOLERANCE:
        category = "error"
        kind = "Laengsluecke (Bahnen auseinandergezogen)"
    elif collinear:
        category = "error"
        kind = "seitlicher Versatz"
    else:
        category = "error"
        kind = f"Versatz (Winkel {angle:.0f} Grad)"

    return {
        "dist": dist, "angle": angle, "lat": lat, "sep": sep,
        "overlap": overlap, "category": category, "kind": kind,
    }


# ----------------------------- Fix-Berechnung -------------------------
def compute_fix(rec):
    """
    Berechnet den Zielpunkt fuer ein Fehlerpaar aus dem Fehler-Record.

    Zwei Geraden:
      A durch (xa,ya) in Richtung (oxa-xa, oya-ya)
      B durch (xb,yb) in Richtung (oxb-xb, oyb-yb)

    Rueckgabe: dict
      status : 'intersection' | 'midpoint' | 'unsolvable'
      tx, ty : Zielkoordinaten (None bei unsolvable)
      label  : Kurztext fuer die Anzeige
      moves  : Liste [(track_id, end, tx, ty), ...] fuer beide Endpunkte
               (leer bei unsolvable)
    """
    ax, ay = rec["xa"], rec["ya"]
    bx, by = rec["xb"], rec["yb"]
    dax, day = rec["oxa"] - ax, rec["oya"] - ay
    dbx, dby = rec["oxb"] - bx, rec["oyb"] - by

    denom = dax * dby - day * dbx  # Kreuzprodukt der Richtungen

    def _moves(tx, ty):
        return [
            (rec["track_a"], rec["end_a"], tx, ty),
            (rec["track_b"], rec["end_b"], tx, ty),
        ]

    # Nicht parallel -> eindeutiger Schnittpunkt der unendlichen Geraden
    if abs(denom) > 1e-12:
        t = ((bx - ax) * dby - (by - ay) * dbx) / denom
        tx = ax + t * dax
        ty = ay + t * day
        return {
            "status": "intersection",
            "tx": tx, "ty": ty,
            "label": "Schnittpunkt der Geraden",
            "moves": _moves(tx, ty),
        }

    # Parallel: kollinear (gleiche Gerade) -> Mittelpunkt der zwei Punkte
    # Querabstand von B zur Geraden A pruefen.
    (uax, uay), La = _unit(dax, day)
    if La > 0:
        gx, gy = bx - ax, by - ay
        lat = abs(gx * (-uay) + gy * uax)
    else:
        lat = math.hypot(bx - ax, by - ay)

    if lat <= SNAP_TOLERANCE:
        tx = (ax + bx) / 2.0
        ty = (ay + by) / 2.0
        return {
            "status": "midpoint",
            "tx": tx, "ty": ty,
            "label": "Mittelpunkt beider Enden (Bahnen kollinear)",
            "moves": _moves(tx, ty),
        }

    # Parallel mit Versatz -> kein Schnittpunkt
    return {
        "status": "unsolvable",
        "tx": None, "ty": None,
        "label": "Unloesbar - parallel mit Versatz (kein Schnittpunkt)",
        "moves": [],
    }


# ----------------------------- gemeinsamer Einstieg -------------------
def analyze_tracks(records):
    """
    records: Liste von Dicts mit
        id, layer, net, x1, y1, x2, y2, width
    Rueckgabe: (real_errors, overlaps, group_lines, stats)
      real_errors / overlaps : Fehler-Records (inkl. 'fix' aus compute_fix)
      group_lines            : {(layer,net): [(id,x1,y1,x2,y2,width), ...]}
      stats                  : {total, groups, singles}
    """
    groups = defaultdict(list)
    group_lines = defaultdict(list)
    total = 0
    skipped = 0

    for r in records:
        x1, y1 = to_float(r.get("x1")), to_float(r.get("y1"))
        x2, y2 = to_float(r.get("x2")), to_float(r.get("y2"))
        w = to_float(r.get("width"))
        wi = w if w is not None else 0.0
        layer = str(r.get("layer", ""))
        net = str(r.get("net", ""))
        tid = r.get("id")
        g = (layer, net)
        total += 1

        # Endpunkt 1: (track_id, x, y, width, other_x, other_y, end)
        if x1 is not None and y1 is not None:
            groups[g].append((tid, x1, y1, wi, x2, y2, 1))
        else:
            skipped += 1
        if x2 is not None and y2 is not None:
            groups[g].append((tid, x2, y2, wi, x1, y1, 2))
        else:
            skipped += 1
        if None not in (x1, y1, x2, y2):
            group_lines[g].append((tid, x1, y1, x2, y2, wi))

    real_errors = []
    overlaps = []
    n_singles = 0

    for gkey, pts in groups.items():
        singles, errors = process_group(pts)
        layer, net = gkey
        n_singles += len(singles)

        for pa, pb, dist, thr in errors:
            info = analyze_pair(pa, pb)
            rec = {
                "layer": layer, "net": net,
                "track_a": pa[0], "xa": pa[1], "ya": pa[2],
                "wa": pa[3], "oxa": pa[4], "oya": pa[5], "end_a": pa[6],
                "track_b": pb[0], "xb": pb[1], "yb": pb[2],
                "wb": pb[3], "oxb": pb[4], "oyb": pb[5], "end_b": pb[6],
                "thr": thr,
            }
            rec.update(info)
            rec["fix"] = compute_fix(rec)
            if info["category"] == "overlap":
                overlaps.append(rec)
            else:
                real_errors.append(rec)

    real_errors.sort(key=lambda e: -e["dist"])
    overlaps.sort(key=lambda e: -e["dist"])

    stats = {"total": total, "groups": len(groups), "singles": n_singles,
             "skipped": skipped}
    return real_errors, overlaps, dict(group_lines), stats


# ----------------------------- SVG / HTML -----------------------------
def esc(s):
    return htmllib.escape(str(s), quote=True)


def _mapper(minx, miny, maxx, maxy, W, H, pad):
    dx = (maxx - minx) or 1.0
    dy = (maxy - miny) or 1.0
    s = min((W - 2 * pad) / dx, (H - 2 * pad) / dy)
    ox = (W - dx * s) / 2.0
    oy = (H - dy * s) / 2.0

    def px(x):
        return ox + (x - minx) * s

    def py(y):
        return H - (oy + (y - miny) * s)

    return px, py, s


def _svg(lines, minx, miny, maxx, maxy, W, H, pad, crosshair=None):
    px, py, _s = _mapper(minx, miny, maxx, maxy, W, H, pad)
    p = [f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'xmlns="http://www.w3.org/2000/svg" class="graph">']
    for seg in lines:
        x1, y1, x2, y2 = seg[0], seg[1], seg[2], seg[3]
        p.append(f'<line x1="{px(x1):.1f}" y1="{py(y1):.1f}" '
                 f'x2="{px(x2):.1f}" y2="{py(y2):.1f}" '
                 f'stroke="#8892a0" stroke-width="1.1" stroke-linecap="round"/>')
    if crosshair:
        mx, my = crosshair
        cx, cy = px(mx), py(my)
        p.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="13" fill="none" '
                 f'stroke="#e5484d" stroke-width="2"/>')
        p.append(f'<line x1="{cx - 22:.1f}" y1="{cy:.1f}" x2="{cx + 22:.1f}" '
                 f'y2="{cy:.1f}" stroke="#e5484d" stroke-width="1"/>')
        p.append(f'<line x1="{cx:.1f}" y1="{cy - 22:.1f}" x2="{cx:.1f}" '
                 f'y2="{cy + 22:.1f}" stroke="#e5484d" stroke-width="1"/>')
    p.append('</svg>')
    return ''.join(p)


def _capsule_path(px, py, ax, ay, ux, uy, r, L):
    nx, ny = -uy, ux
    e1 = (ax + r * nx + L * ux, ay + r * ny + L * uy)
    e2 = (ax - r * nx + L * ux, ay - r * ny + L * uy)
    phi0 = math.atan2(-uy, -ux)
    N = 20
    a0 = phi0 - math.pi / 2.0
    d = [f'M {px(e1[0]):.1f} {py(e1[1]):.1f}']
    for i in range(N + 1):
        a = a0 + math.pi * (i / N)
        wx, wy = ax + r * math.cos(a), ay + r * math.sin(a)
        d.append(f'L {px(wx):.1f} {py(wy):.1f}')
    d.append(f'L {px(e2[0]):.1f} {py(e2[1]):.1f}')
    return ' '.join(d)


def _zoom_svg(context_lines, tA, tB, minx, miny, maxx, maxy, W, H, pad,
              clip_id, target=None):
    """Zoom-Grafik + optional gruen markierter Zielpunkt (Fix)."""
    px, py, s = _mapper(minx, miny, maxx, maxy, W, H, pad)
    span = maxx - minx
    p = [f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'xmlns="http://www.w3.org/2000/svg" class="graph">']

    for seg in context_lines:
        x1, y1, x2, y2 = seg[0], seg[1], seg[2], seg[3]
        p.append(f'<line x1="{px(x1):.1f}" y1="{py(y1):.1f}" '
                 f'x2="{px(x2):.1f}" y2="{py(y2):.1f}" '
                 f'stroke="#c7cdd6" stroke-width="1" stroke-linecap="round"/>')

    ax, ay, uax, uay, rA, lenA = tA
    bx, by, ubx, uby, rB, lenB = tB

    p.append(f'<defs><clipPath id="{clip_id}">'
             f'<circle cx="{px(bx):.1f}" cy="{py(by):.1f}" r="{rB * s:.1f}"/>'
             f'</clipPath></defs>')
    p.append(f'<circle cx="{px(ax):.1f}" cy="{py(ay):.1f}" r="{rA * s:.1f}" '
             f'fill="#e5484d" fill-opacity="0.35" clip-path="url(#{clip_id})"/>')

    LA = min(lenA, span * 2.0)
    LB = min(lenB, span * 2.0)
    for (cx, cy, ux, uy, r, L) in ((ax, ay, uax, uay, rA, LA),
                                   (bx, by, ubx, uby, rB, LB)):
        dpath = _capsule_path(px, py, cx, cy, ux, uy, r, L)
        p.append(f'<path d="{dpath}" fill="none" stroke="#2f6fc0" '
                 f'stroke-width="1.6" stroke-linejoin="round"/>')

    for (cx, cy) in ((ax, ay), (bx, by)):
        p.append(f'<circle cx="{px(cx):.1f}" cy="{py(cy):.1f}" r="3" fill="#e5484d"/>')
    p.append(f'<line x1="{px(ax):.1f}" y1="{py(ay):.1f}" '
             f'x2="{px(bx):.1f}" y2="{py(by):.1f}" '
             f'stroke="#e5484d" stroke-width="1" stroke-dasharray="3,2"/>')

    # Zielpunkt (Fix): gruener Marker + gestrichelte Pfeile von beiden Enden
    if target is not None:
        tx, ty = target
        tpx, tpy = px(tx), py(ty)
        p.append('<defs><marker id="arh" markerWidth="7" markerHeight="7" '
                 'refX="5" refY="2.5" orient="auto">'
                 '<path d="M0,0 L5,2.5 L0,5 z" fill="#1a7f37"/></marker></defs>')
        for (cx, cy) in ((ax, ay), (bx, by)):
            p.append(f'<line x1="{px(cx):.1f}" y1="{py(cy):.1f}" '
                     f'x2="{tpx:.1f}" y2="{tpy:.1f}" stroke="#1a7f37" '
                     f'stroke-width="1.2" stroke-dasharray="4,2" '
                     f'marker-end="url(#arh)"/>')
        p.append(f'<circle cx="{tpx:.1f}" cy="{tpy:.1f}" r="5.5" fill="none" '
                 f'stroke="#1a7f37" stroke-width="2"/>')
        p.append(f'<circle cx="{tpx:.1f}" cy="{tpy:.1f}" r="2" fill="#1a7f37"/>')

    p.append('</svg>')
    return ''.join(p)


def _fix_block_html(e, server_mode):
    """Fix-Zeile: Art, Zielkoordinaten, Verschiebung, Button (nur Server-Modus)."""
    fix = e["fix"]
    status = fix["status"]

    if status == "unsolvable":
        return (f'<div class="fix fix-unsolv">'
                f'<span class="fixlabel">Fix: {esc(fix["label"])}</span></div>')

    tx, ty = fix["tx"], fix["ty"]
    da = math.hypot(tx - e["xa"], ty - e["ya"])
    db = math.hypot(tx - e["xb"], ty - e["yb"])
    coord = (f'Ziel <b>X {tx:.{ROUND_DECIMALS}f} / Y {ty:.{ROUND_DECIMALS}f} mm</b>'
             f' &middot; verschiebt A um {da:.{ROUND_DECIMALS}f}, '
             f'B um {db:.{ROUND_DECIMALS}f} mm')

    btn = ''
    if server_mode:
        btn = (f'<button class="fixbtn" '
               f'onclick="doFix(this,\'{esc(e["fix_id"])}\')">'
               f'In Altium fixen</button>')
    else:
        btn = ('<span class="fixhint">(Vorschau &ndash; Fix-Button nur im '
               'Altium-Modus)</span>')

    return (f'<div class="fix">'
            f'<span class="fixlabel">Fix: {esc(fix["label"])}</span>'
            f'<span class="fixcoord">{coord}</span>'
            f'{btn}'
            f'<span class="fixstate"></span>'
            f'</div>')


def _error_block(e, group_lines, idx, server_mode):
    layer, net = e["layer"], e["net"]
    xa, ya, xb, yb = e["xa"], e["ya"], e["xb"], e["yb"]
    d = e["dist"]

    search = f"(ObjectKind = '{FILTER_KIND}') And (Layer = '{layer}') And (Net = '{net}')"

    lines = [(l[1], l[2], l[3], l[4], l[5]) for l in group_lines.get((layer, net), [])]

    pts = [(xa, ya), (xb, yb)]
    for (x1, y1, x2, y2, _w) in lines:
        pts.append((x1, y1))
        pts.append((x2, y2))
    fix = e["fix"]
    if fix["tx"] is not None:
        pts.append((fix["tx"], fix["ty"]))
    minx = min(p[0] for p in pts)
    maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts)
    maxy = max(p[1] for p in pts)
    span = max(maxx - minx, maxy - miny, 1e-6)
    m = span * 0.06

    mx, my = (xa + xb) / 2.0, (ya + yb) / 2.0
    overview = _svg(lines, minx - m, miny - m, maxx + m, maxy + m,
                    380, 280, 14, crosshair=(mx, my))

    (uax, uay), lenA = _unit(e["oxa"] - xa, e["oya"] - ya)
    (ubx, uby), lenB = _unit(e["oxb"] - xb, e["oyb"] - yb)
    rA, rB = e["wa"] / 2.0, e["wb"] / 2.0
    tA = (xa, ya, uax, uay, rA, lenA)
    tB = (xb, yb, ubx, uby, rB, lenB)

    rmax = max(rA, rB, 0.0)
    half = max((d * 0.5 + rmax) * 1.35, 0.03)
    target = (fix["tx"], fix["ty"]) if fix["tx"] is not None else None
    # Zoom-Fenster ggf. so weiten, dass der Zielpunkt sichtbar bleibt.
    zminx, zminy = mx - half, my - half
    zmaxx, zmaxy = mx + half, my + half
    if target is not None:
        tx, ty = target
        zminx = min(zminx, tx - rmax)
        zmaxx = max(zmaxx, tx + rmax)
        zminy = min(zminy, ty - rmax)
        zmaxy = max(zmaxy, ty + rmax)
    zoom = _zoom_svg(lines, tA, tB, zminx, zminy, zmaxx, zmaxy,
                     320, 300, 14, clip_id=f"clip{idx}", target=target)

    fixhtml = _fix_block_html(e, server_mode)

    data_fix = f' data-fix-id="{esc(e["fix_id"])}"' if server_mode else ''

    return f'''<div class="err" data-dist="{d:.5f}" data-overlap="{e["overlap"]:.2f}" data-layer="{esc(layer)}"{data_fix}>
  <div class="search">
    <code>{esc(search)}</code>
    <button onclick="cp(this)">Kopieren</button>
  </div>
  <div class="dist">Abstand: <b>{d:.4f} mm</b>
     &nbsp;&middot;&nbsp; Ueberlappung: <b>{e["overlap"]:.0f}%</b>
     &nbsp;&middot;&nbsp; {esc(e["kind"])}</div>
  <div class="sub">Width A {e["wa"]:.3f} / B {e["wb"]:.3f} mm &middot;
     quer {e["lat"]:.4f} mm &middot; laengs {e["sep"]:+.4f} mm &middot;
     Track A #{esc(e["track_a"])} (Ende {e["end_a"]}) &harr;
     Track B #{esc(e["track_b"])} (Ende {e["end_b"]})</div>
  {fixhtml}
  <div class="graphs">
    <figure>{overview}<figcaption>Uebersicht Gruppe</figcaption></figure>
    <figure>{zoom}<figcaption>Zoom &middot; rot = Ist, gruen = Fix-Ziel</figcaption></figure>
  </div>
  <div class="status">
    <button class="stbtn" onclick="setState(this,'ignored')">Ignorieren</button>
    <button class="stbtn" onclick="setState(this,'fixed')">Behoben</button>
    <span class="badge"></span>
  </div>
</div>'''


def build_html(real_errors, overlaps, group_lines, stats, filename,
               server_mode=False):
    """Baut den kompletten HTML-Report. server_mode -> Fix-Buttons + Polling."""
    total = stats["total"]
    ng = stats["groups"]
    n_singles = stats["singles"]

    # fix_id vergeben (fortlaufend ueber beide Kategorien)
    fid = 0
    for e in real_errors:
        e["fix_id"] = str(fid); fid += 1
    for e in overlaps:
        e["fix_id"] = str(fid); fid += 1

    parts = []
    idx = 0
    if real_errors:
        parts.append('<h2 class="sec">Naeherungs-Fehler '
                     f'<span>({len(real_errors)})</span></h2>')
        parts.append('<div class="blocks">')
        for e in real_errors:
            parts.append(_error_block(e, group_lines, idx, server_mode))
            idx += 1
        parts.append('</div>')
    else:
        parts.append('<p class="ok">Keine Naeherungs-Fehler gefunden.</p>')

    if overlaps:
        parts.append('<h2 class="sec sec-ov">Positive Ueberlappungen &ndash; harmlos '
                     f'<span>({len(overlaps)})</span></h2>')
        parts.append('<p class="hint">Kollineare Bahnen, die ineinander laufen. '
                     'Technisch ein Fehler, elektrisch aber verbunden. '
                     'Fix optional.</p>')
        parts.append('<div class="blocks">')
        for e in overlaps:
            parts.append(_error_block(e, group_lines, idx, server_mode))
            idx += 1
        parts.append('</div>')

    body = "\n".join(parts)

    sortbar = ''
    if real_errors or overlaps:
        mode_badge = ('<span class="modebadge live">Altium-Live-Modus</span>'
                      if server_mode else
                      '<span class="modebadge">Statischer Report</span>')
        sortbar = (
            '<div class="sortbar">Sortieren nach:'
            '<button class="sortbtn active" onclick="sortBy(\'dist\',this)">'
            'Abstand &darr; (groesster zuerst)</button>'
            '<button class="sortbtn" onclick="sortBy(\'overlap\',this)">'
            'Ueberlappung &uarr; (kleinste zuerst)</button>'
            '<label style="margin-left:14px"><input type="checkbox" id="hideDone" '
            'onchange="applyFilter()"> erledigte ausblenden</label>'
            f'{mode_badge}'
            '<span class="badge" id="openCount" style="margin-left:8px"></span></div>'
        )

    # Layer-Filterleiste: pro vorkommendem Layer eine Checkbox (Anzahl Fehler).
    layerbar = ''
    if real_errors or overlaps:
        from collections import Counter
        counts = Counter(e["layer"] for e in list(real_errors) + list(overlaps))
        chks = []
        for layer in sorted(counts):
            chks.append(
                '<label class="laychk"><input type="checkbox" class="layerbox" '
                f'value="{esc(layer)}" checked onchange="applyFilter()"> '
                f'{esc(layer)} <span class="laycount">({counts[layer]})</span></label>'
            )
        layerbar = (
            '<div class="layerbar">Layer:'
            '<button class="laytoggle" onclick="allLayers(true)">alle</button>'
            '<button class="laytoggle" onclick="allLayers(false)">keine</button>'
            + ''.join(chks) +
            '</div>'
        )

    style = _STYLE
    script = _script(server_mode)

    return f'''<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Verbindungs-Check &ndash; {esc(filename)}</title>
<style>{style}</style>
</head>
<body>
<header>
  <h1>Verbindungs-Check &ndash; Naeherungs-Fehler</h1>
  <div class="meta">Quelle: <b>{esc(filename)}</b> &nbsp;&middot;&nbsp;
    Tracks: <b>{total}</b> &nbsp;&middot;&nbsp;
    Gruppen: <b>{ng}</b> &nbsp;&middot;&nbsp;
    Einzelpunkte: <b>{n_singles}</b> &nbsp;&middot;&nbsp;
    Fehler: <b>{len(real_errors)}</b> &nbsp;&middot;&nbsp;
    Ueberlappungen: <b>{len(overlaps)}</b></div>
</header>
{sortbar}
{layerbar}
<main>
{body}
</main>
<script>{script}</script>
</body>
</html>'''


_STYLE = """
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif;
           margin: 0; background: #f4f5f7; color: #1b1f24; }
    header { background: #fff; border-bottom: 1px solid #e3e6ea; padding: 18px 24px; }
    header h1 { margin: 0 0 4px; font-size: 18px; }
    header .meta { font-size: 13px; color: #5f6b7c; }
    header .meta b { color: #1b1f24; }
    .sortbar { position: sticky; top: 0; z-index: 5; background: #fff;
               border-bottom: 1px solid #e3e6ea; padding: 10px 24px;
               font-size: 13px; color: #5f6b7c; display: flex; gap: 8px;
               align-items: center; flex-wrap: wrap; }
    .sortbtn { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
               padding: 5px 12px; cursor: pointer; font-size: 13px; color: #384250; }
    .sortbtn:hover { background: #eef0f3; }
    .sortbtn.active { background: #1b1f24; color: #fff; border-color: #1b1f24; }
    .modebadge { font-size: 12px; padding: 3px 9px; border-radius: 10px;
                 background: #eef0f3; color: #5f6b7c; margin-left: 14px; }
    .modebadge.live { background: #1a7f37; color: #fff; }
    .layerbar { position: sticky; top: 41px; z-index: 4; background: #fbfbfc;
                border-bottom: 1px solid #e3e6ea; padding: 8px 24px;
                font-size: 13px; color: #5f6b7c; display: flex; gap: 10px;
                align-items: center; flex-wrap: wrap; }
    .laychk { display: inline-flex; align-items: center; gap: 4px;
              background: #fff; border: 1px solid #e3e6ea; border-radius: 6px;
              padding: 3px 9px; cursor: pointer; color: #384250; }
    .laycount { color: #97a1af; }
    .laytoggle { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
                 padding: 3px 9px; cursor: pointer; font-size: 12px; color: #384250; }
    .laytoggle:hover { background: #eef0f3; }
    main { max-width: 1040px; margin: 0 auto; padding: 20px 16px 60px; }
    .err { background: #fff; border: 1px solid #e3e6ea; border-radius: 10px;
           padding: 16px 18px; margin: 0 0 18px; transition: opacity .15s; }
    .err.ignored { opacity: .5; border-left: 4px solid #97a1af; }
    .err.fixed { opacity: .55; border-left: 4px solid #1a7f37; }
    .err.stale { border-left: 4px solid #d4a017; }
    .search { display: flex; gap: 8px; align-items: stretch; margin-bottom: 10px; }
    .search code { flex: 1; background: #0f1116; color: #e6edf3; border-radius: 6px;
                   padding: 9px 12px; font-size: 13px; overflow-x: auto; white-space: nowrap; }
    .search button { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
                     padding: 0 14px; cursor: pointer; font-size: 13px; }
    .search button:hover { background: #eef0f3; }
    .dist { font-size: 14px; margin-bottom: 4px; }
    .dist b { color: #c4302b; }
    .sub { font-size: 12px; color: #5f6b7c; margin-bottom: 12px; }
    .fix { display: flex; gap: 10px; align-items: center; flex-wrap: wrap;
           background: #f0f7f1; border: 1px solid #cfe6d4; border-radius: 8px;
           padding: 9px 12px; margin-bottom: 12px; font-size: 13px; }
    .fix-unsolv { background: #fbf4e6; border-color: #eddcae; }
    .fixlabel { font-weight: 600; color: #1a5e2e; }
    .fix-unsolv .fixlabel { color: #8a6d1a; }
    .fixcoord { color: #384250; }
    .fixcoord b { color: #1b1f24; }
    .fixbtn { border: 1px solid #1a7f37; background: #1a7f37; color: #fff;
              border-radius: 6px; padding: 6px 14px; cursor: pointer; font-size: 13px;
              margin-left: auto; }
    .fixbtn:hover { background: #166a2e; }
    .fixbtn:disabled { opacity: .6; cursor: default; }
    .fixhint { margin-left: auto; color: #7a8494; font-style: italic; }
    .fixstate { font-size: 12px; min-width: 90px; text-align: right; }
    .fixstate.sending { color: #8a6d1a; }
    .fixstate.done { color: #1a7f37; font-weight: 600; }
    .fixstate.failed { color: #c4302b; font-weight: 600; }
    .sec { margin: 26px 0 12px; font-size: 15px; text-transform: uppercase;
           letter-spacing: .04em; color: #384250; }
    .sec span { color: #97a1af; font-weight: 400; }
    .sec-ov { color: #7a6a1f; }
    .hint { margin: -6px 0 14px; font-size: 13px; color: #5f6b7c; }
    .graphs { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
    figure { margin: 0; }
    figcaption { font-size: 12px; color: #5f6b7c; text-align: center; margin-top: 4px; }
    .graph { background: #fff; border: 1px solid #e3e6ea; border-radius: 8px; display: block; }
    .status { display: flex; gap: 8px; align-items: center; margin-top: 12px;
              padding-top: 10px; border-top: 1px solid #eef0f3; }
    .stbtn { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
             padding: 5px 12px; cursor: pointer; font-size: 13px; color: #384250; }
    .stbtn:hover { background: #eef0f3; }
    .stbtn.on-ign { background: #97a1af; color: #fff; border-color: #97a1af; }
    .stbtn.on-fix { background: #1a7f37; color: #fff; border-color: #1a7f37; }
    .badge { font-size: 12px; color: #5f6b7c; margin-left: auto; }
    .stalemsg { display: none; font-size: 12px; color: #8a6d1a; margin-top: 8px; }
    .err.stale .stalemsg { display: block; }
    .ok { font-size: 16px; color: #1a7f37; background: #fff; border: 1px solid #e3e6ea;
          border-radius: 10px; padding: 20px; text-align: center; }
    """


def _script(server_mode):
    base = r"""
    function cp(btn){
      var code = btn.parentElement.querySelector('code').innerText;
      function done(){ var t = btn.innerText; btn.innerText = 'Kopiert'; setTimeout(function(){ btn.innerText = t; }, 1200); }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code).then(done).catch(function(){ fb(code, done); });
      } else { fb(code, done); }
    }
    function fb(text, done){
      var ta = document.createElement('textarea'); ta.value = text;
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch(e) {}
      document.body.removeChild(ta);
    }
    function sortBy(key, btn){
      document.querySelectorAll('.blocks').forEach(function(c){
        var items = Array.prototype.slice.call(c.children);
        items.sort(function(a, b){
          var av = parseFloat(a.dataset[key]), bv = parseFloat(b.dataset[key]);
          return key === 'dist' ? bv - av : av - bv;
        });
        items.forEach(function(it){ c.appendChild(it); });
      });
      document.querySelectorAll('.sortbtn').forEach(function(x){ x.classList.remove('active'); });
      btn.classList.add('active');
    }
    var LABEL = { ignored: 'Ignoriert', fixed: 'Behoben' };
    function setState(btn, state){
      var err = btn.closest('.err');
      var cur = err.getAttribute('data-state') || '';
      var next = (cur === state) ? '' : state;
      err.setAttribute('data-state', next);
      err.classList.remove('ignored', 'fixed');
      if (next) err.classList.add(next);
      var st = err.querySelector('.status');
      st.querySelectorAll('.stbtn').forEach(function(b){ b.classList.remove('on-ign', 'on-fix'); });
      if (next === 'ignored') st.querySelectorAll('.stbtn')[0].classList.add('on-ign');
      if (next === 'fixed')   st.querySelectorAll('.stbtn')[1].classList.add('on-fix');
      err.querySelector('.badge').textContent = next ? LABEL[next] : '';
      applyFilter(); updateCounts();
    }
    function enabledLayers(){
      var set = {};
      document.querySelectorAll('.layerbox').forEach(function(cb){
        if (cb.checked) set[cb.value] = true;
      });
      return set;
    }
    function allLayers(on){
      document.querySelectorAll('.layerbox').forEach(function(cb){ cb.checked = on; });
      applyFilter();
    }
    function applyFilter(){
      var hide = document.getElementById('hideDone');
      hide = hide && hide.checked;
      var lay = enabledLayers();
      document.querySelectorAll('.err').forEach(function(e){
        var handled = !!e.getAttribute('data-state');
        var layerOff = !lay[e.getAttribute('data-layer')];
        e.style.display = ((hide && handled) || layerOff) ? 'none' : '';
      });
      updateCounts();
    }
    function updateCounts(){
      // nur per Layer sichtbare Bloecke zaehlen
      var lay = enabledLayers();
      var all = 0, done = 0;
      document.querySelectorAll('.err').forEach(function(e){
        if (!lay[e.getAttribute('data-layer')]) return;
        all++;
        if (e.getAttribute('data-state')) done++;
      });
      var el = document.getElementById('openCount');
      if (el) el.textContent = (all - done) + ' / ' + all + ' offen';
    }
    document.addEventListener('DOMContentLoaded', updateCounts);
    """

    if not server_mode:
        return base

    live = r"""
    // ---- Altium-Live-Modus ----
    function errByFix(fid){
      return document.querySelector('.err[data-fix-id="'+fid+'"]');
    }
    function doFix(btn, fid){
      btn.disabled = true;
      var err = btn.closest('.err');
      var stel = err.querySelector('.fixstate');
      stel.className = 'fixstate sending';
      stel.textContent = 'gesendet ...';
      fetch('/fix', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({fix_id: fid})
      }).then(function(r){ return r.json(); }).then(function(j){
        if (!j.ok){
          stel.className = 'fixstate failed';
          stel.textContent = j.error || 'Fehler';
          btn.disabled = false;
        }
        // Erfolg wird ueber /status-Polling bestaetigt.
      }).catch(function(){
        stel.className = 'fixstate failed';
        stel.textContent = 'Server weg?';
        btn.disabled = false;
      });
    }
    function markStale(fids){
      fids.forEach(function(fid){
        var err = errByFix(fid);
        if (err && !err.classList.contains('fixed')) err.classList.add('stale');
      });
    }
    function pollStatus(){
      fetch('/status').then(function(r){ return r.json(); }).then(function(j){
        var states = j.states || {};
        var affectedTracks = {};
        Object.keys(states).forEach(function(fid){
          var s = states[fid];
          var err = errByFix(fid);
          if (!err) return;
          var stel = err.querySelector('.fixstate');
          var btn = err.querySelector('.fixbtn');
          if (s === 'done'){
            stel.className = 'fixstate done';
            stel.textContent = 'Behoben in Altium';
            if (btn) btn.disabled = true;
            if (!err.getAttribute('data-state')) setStateSilent(err, 'fixed');
          } else if (s === 'failed'){
            stel.className = 'fixstate failed';
            stel.textContent = 'Altium-Fehler';
            if (btn) btn.disabled = false;
          } else if (s === 'pending' || s === 'queued'){
            stel.className = 'fixstate sending';
            stel.textContent = 'wartet auf Altium ...';
          }
        });
        // veraltete Bloecke markieren (Tracks, die schon gefixt wurden)
        if (j.stale) markStale(j.stale);
      }).catch(function(){}).finally(function(){
        setTimeout(pollStatus, 800);
      });
    }
    function setStateSilent(err, state){
      err.setAttribute('data-state', state);
      err.classList.add(state);
      var st = err.querySelector('.status');
      if (state === 'fixed') st.querySelectorAll('.stbtn')[1].classList.add('on-fix');
      err.querySelector('.badge').textContent = LABEL[state] || '';
      applyFilter(); updateCounts();
    }
    document.addEventListener('DOMContentLoaded', pollStatus);
    """
    return base + live
