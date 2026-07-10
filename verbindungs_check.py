#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Verbindungs-Check fuer Linien-/Track-Listen aus Excel.

Idee / Logik:
- Jede Zeile ist eine Linie mit zwei Endpunkten: (X1,Y1) und (X2,Y2).
- Gruppiert wird nach (Layer, Net). ALLE Checks laufen nur innerhalb einer Gruppe.
- Endpunkte, die exakt aufeinander liegen (aus verschiedenen Zeilen), gelten als
  verbunden -> "Partner". Diese Punkte sind ok.
- Punkte ohne Partner sind erstmal in Ordnung (das sind die echten Linien-Enden),
  werden aber separat gelistet.
- ABER: liegen zwei partnerlose Punkte naeher beieinander als die Breite (Width),
  dann sollten sie eigentlich aufeinander liegen -> das wird als FEHLER gemeldet.
- Bei der Radius-/Naeherungs-Suche wird der andere Endpunkt aus DERSELBEN Zeile
  ignoriert.

Bedienung:
  python verbindungs_check.py
  -> Datei-Explorer oeffnet sich, Excel auswaehlen.
  -> Report wird als *_check_report.html neben der Eingabedatei gespeichert.

Abhaengigkeiten:
  pip install pandas openpyxl
  (tkinter ist bei Standard-Python unter Windows dabei)
"""

import os
import sys
import math
import html as htmllib
import webbrowser
from collections import defaultdict

try:
    import pandas as pd
except ImportError:
    sys.exit("pandas fehlt. Bitte installieren:  pip install pandas openpyxl")

import tkinter as tk
from tkinter import filedialog, messagebox


# ============================ Konfiguration ============================
# Zwei Punkte gelten als "gleiche Stelle" (verbunden), wenn ihr ABSTAND
# kleiner/gleich dieser Toleranz ist. Verschwindend kleine Abstaende (z.B.
# 0,004 mm) werden damit als verbunden behandelt und NICHT als Fehler gemeldet.
SNAP_TOLERANCE = 0.01   # mm

# Zwei Bahnen gelten als "gleiche Ausrichtung" (kollinear), wenn ihr Winkel
# hoechstens so gross ist. Relevant fuer die Kategorie "positive Ueberlappung".
ANGLE_TOL_DEG = 8.0

# Anzeige-Genauigkeit der Koordinaten im Report (rein kosmetisch).
ROUND_DECIMALS = 3

# Nur Zeilen werten, bei denen Spalte "Object Kind" diesen Wert hat (Gross/Klein egal).
# Filtert damit automatisch Kopfzeile und Fremdzeilen weg.
FILTER_KIND = "Track"

# Spalten werden anhand von Schluesselwoertern gesucht (Gross/Klein egal).
# So funktioniert es auch, wenn die Ueberschrift z.B. "X1 (mm)" heisst.
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
    # deutsche Zahl: Punkt = Tausendertrenner, Komma = Dezimal
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


def _build_grid(points, cell):
    """Ordnet Punkt-Indizes in ein Raster mit Zellgroesse `cell` ein."""
    grid = defaultdict(list)
    for idx, p in enumerate(points):
        cx = int(math.floor(p[1] / cell))
        cy = int(math.floor(p[2] / cell))
        grid[(cx, cy)].append(idx)
    return grid


def _neighbors(grid, cx, cy):
    """Alle Punkt-Indizes in der Zelle (cx,cy) und den 8 Nachbarzellen."""
    out = []
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            out.extend(grid.get((cx + dx, cy + dy), ()))
    return out


def process_group(points):
    """
    points: Liste von (row, x, y, width) einer Gruppe.
    Rueckgabe: (singles, errors)
      singles: partnerlose Punkte (row, x, y, width)
      errors:  Naeherungs-Fehler als (pa, pb, dist, thr)

    Ablauf (immer erst Abstand rechnen, dann Schwelle):
      1) Partner-Erkennung: ein Punkt hat einen Partner, wenn ein Punkt aus einer
         ANDEREN Zeile im Abstand <= SNAP_TOLERANCE liegt. Solche Punkte gelten als
         verbunden (gleiche Stelle) und sind ok. Minimale Abstaende (z.B. 0,004 mm)
         verschwinden damit sauber, statt als Fehler aufzutauchen.
      2) Naeherungs-Check nur zwischen partnerlosen Punkten: Abstand rechnen, und
         wenn SNAP_TOLERANCE < Abstand <= Width -> Fehler (sollten eigentlich
         aufeinander liegen). Der andere Endpunkt derselben Zeile wird ignoriert.
    """
    n = len(points)

    # --- Schritt 1: Partner-Erkennung ueber ABSTAND (Toleranz) ---
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
                        continue  # gleiche Zeile zaehlt nicht als Partner
                    dist = math.hypot(pa[1] - pb[1], pa[2] - pb[2])
                    if dist <= SNAP_TOLERANCE:
                        paired[a] = True
                        break

    unpaired = [points[i] for i in range(n) if not paired[i]]

    # --- Schritt 2: Naeherungs-Check zwischen partnerlosen Punkten ---
    errors = []
    if len(unpaired) >= 2:
        maxw = max((p[3] for p in unpaired), default=0.0)
        cell = maxw if maxw > 0 else 0.001  # Zellgroesse = groesste Breite
        grid = _build_grid(unpaired, cell)
        for (cx, cy), idxs in grid.items():
            cand = _neighbors(grid, cx, cy)
            for a in idxs:
                pa = unpaired[a]
                for b in cand:
                    if b <= a:
                        continue  # jedes Paar nur einmal
                    pb = unpaired[b]
                    if pa[0] == pb[0]:
                        continue  # gleiche Zeile ignorieren
                    thr = max(pa[3], pb[3])
                    if thr <= 0:
                        continue
                    dist = math.hypot(pa[1] - pb[1], pa[2] - pb[2])
                    # verschwindend kleine Abstaende gelten als verbunden -> ignorieren
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
    """
    Ueberlappung zweier Kreise (Radius rA, rB, Mittelpunktabstand d) in Prozent,
    bezogen auf die Flaeche des KLEINEREN Kreises.
    d = 0  -> 100 %   |   d >= rA+rB -> 0 %
    Modelliert die runden Bahnenden (Radius = width/2).
    """
    if rA <= 0 or rB <= 0:
        return 0.0
    if d >= rA + rB:
        return 0.0
    rmin = min(rA, rB)
    if d <= abs(rA - rB):
        return 100.0  # kleinerer Kreis liegt komplett im groesseren
    a = rA * rA * math.acos((d * d + rA * rA - rB * rB) / (2 * d * rA))
    b = rB * rB * math.acos((d * d + rB * rB - rA * rA) / (2 * d * rB))
    c = 0.5 * math.sqrt(max(0.0, (-d + rA + rB) * (d + rA - rB) *
                            (d - rA + rB) * (d + rA + rB)))
    lens = a + b - c
    return lens / (math.pi * rmin * rmin) * 100.0


def analyze_pair(pa, pb):
    """
    Geometrie zweier partnerloser Endpunkte (inkl. ihrer Bahnrichtung).
    Punkt-Tupel: (row, x, y, width, other_x, other_y)

    Liefert dict mit:
      dist       - Abstand der Endpunkte
      angle      - Winkel zwischen den beiden Bahnen (0..90 Grad)
      lat        - seitlicher Versatz (quer zur Bahn)
      sep        - Laengsversatz: >0 = Luecke (auseinander), <0 = Ueberlappung
      overlap    - Ueberlappung der End-Kreise (Radius width/2) in Prozent
      category   - 'overlap' (positive Ueberlappung, harmlos) oder 'error'
      kind       - Kurztext zur Art der Abweichung
    """
    ax, ay = pa[1], pa[2]
    bx, by = pb[1], pb[2]
    uA, _ = _unit(pa[4] - ax, pa[5] - ay)  # Richtung in Bahn A hinein
    uB, _ = _unit(pb[4] - bx, pb[5] - by)  # Richtung in Bahn B hinein

    gx, gy = bx - ax, by - ay
    dist = math.hypot(gx, gy)

    Wa, Wb = pa[3], pb[3]

    # Winkel zwischen den (ungerichteten) Bahnen: 0 = kollinear, 90 = rechtwinklig
    dot = uA[0] * uB[0] + uA[1] * uB[1]
    dotc = max(-1.0, min(1.0, dot))
    angle = math.degrees(math.acos(abs(dotc)))
    continuation = dot < 0  # Bahnen zeigen voneinander weg -> echte Fortsetzung

    # Zerlegung im Koordinatensystem von Bahn A: laengs (uA) und quer (Normale)
    gpar = gx * uA[0] + gy * uA[1]
    gperp = gx * (-uA[1]) + gy * uA[0]
    lat = abs(gperp)
    sep = -gpar  # >0 = Laengsluecke, <0 = Laengsueberlappung

    # Ueberlappung ueber die runden Bahnenden (Kreise mit Radius width/2)
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


def _mapper(minx, miny, maxx, maxy, W, H, pad):
    """Liefert (px, py, s): Welt->Pixel (Y nach oben), plus Pixel-pro-mm-Skala s."""
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
    """Uebersichts-SVG: duenne Linien + optional ein rotes Fadenkreuz."""
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
    """
    Umriss eines Bahnendes: Halbkreis-Cap (Radius r) am Punkt + zwei parallele
    Seitenlinien in Bahnrichtung (Laenge L). Rueckgabe: SVG-Path-'d' (nicht gefuellt).
    """
    nx, ny = -uy, ux                      # Normale zur Bahn
    e1 = (ax + r * nx + L * ux, ay + r * ny + L * uy)
    e2 = (ax - r * nx + L * ux, ay - r * ny + L * uy)
    # Halbkreis auf der -u-Seite (die freie Stirnseite), von +n nach -n
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


def _zoom_svg(context_lines, tA, tB, minx, miny, maxx, maxy, W, H, pad, clip_id):
    """
    Zoom-Grafik: beide Bahnen als Umriss (Halbkreis-Cap + 2 Seitenlinien),
    die Schnittmenge der beiden End-Kreise (Radius width/2) eingefaerbt.
    tA/tB = (x, y, ux, uy, r, laenge_ins_body)
    """
    px, py, s = _mapper(minx, miny, maxx, maxy, W, H, pad)
    span = maxx - minx
    p = [f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'xmlns="http://www.w3.org/2000/svg" class="graph">']

    # Kontext: andere Bahnen der Gruppe ganz dezent
    for seg in context_lines:
        x1, y1, x2, y2 = seg[0], seg[1], seg[2], seg[3]
        p.append(f'<line x1="{px(x1):.1f}" y1="{py(y1):.1f}" '
                 f'x2="{px(x2):.1f}" y2="{py(y2):.1f}" '
                 f'stroke="#c7cdd6" stroke-width="1" stroke-linecap="round"/>')

    ax, ay, uax, uay, rA, lenA = tA
    bx, by, ubx, uby, rB, lenB = tB

    # Schnittmenge der beiden Kreise einfaerben (Kreis A, auf Kreis B geclippt)
    p.append(f'<defs><clipPath id="{clip_id}">'
             f'<circle cx="{px(bx):.1f}" cy="{py(by):.1f}" r="{rB * s:.1f}"/>'
             f'</clipPath></defs>')
    p.append(f'<circle cx="{px(ax):.1f}" cy="{py(ay):.1f}" r="{rA * s:.1f}" '
             f'fill="#e5484d" fill-opacity="0.35" clip-path="url(#{clip_id})"/>')

    # Umrisse der beiden Bahnenden
    LA = min(lenA, span * 2.0)
    LB = min(lenB, span * 2.0)
    for (cx, cy, ux, uy, r, L) in ((ax, ay, uax, uay, rA, LA),
                                   (bx, by, ubx, uby, rB, LB)):
        dpath = _capsule_path(px, py, cx, cy, ux, uy, r, L)
        p.append(f'<path d="{dpath}" fill="none" stroke="#2f6fc0" '
                 f'stroke-width="1.6" stroke-linejoin="round"/>')

    # Mittelpunkte
    for (cx, cy) in ((ax, ay), (bx, by)):
        p.append(f'<circle cx="{px(cx):.1f}" cy="{py(cy):.1f}" r="3" fill="#e5484d"/>')
    # Verbindung der beiden Punkte
    p.append(f'<line x1="{px(ax):.1f}" y1="{py(ay):.1f}" '
             f'x2="{px(bx):.1f}" y2="{py(by):.1f}" '
             f'stroke="#e5484d" stroke-width="1" stroke-dasharray="3,2"/>')
    p.append('</svg>')
    return ''.join(p)


def _error_block(e, group_lines, idx):
    """Ein Fehler-Block: Suchstring, Abstand + Kennzahlen, Grafik (Uebersicht + Zoom)."""
    layer, net = e["layer"], e["net"]
    xa, ya, xb, yb = e["xa"], e["ya"], e["xb"], e["yb"]
    d = e["dist"]

    search = f"(ObjectKind = '{FILTER_KIND}') And (Layer = '{layer}') And (Net = '{net}')"

    lines = [(l[1], l[2], l[3], l[4], l[5]) for l in group_lines.get((layer, net), [])]

    # Bounding-Box der Gruppe (inkl. Fehlerpunkte)
    pts = [(xa, ya), (xb, yb)]
    for (x1, y1, x2, y2, _w) in lines:
        pts.append((x1, y1))
        pts.append((x2, y2))
    minx = min(p[0] for p in pts)
    maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts)
    maxy = max(p[1] for p in pts)
    span = max(maxx - minx, maxy - miny, 1e-6)
    m = span * 0.06

    mx, my = (xa + xb) / 2.0, (ya + yb) / 2.0
    overview = _svg(lines, minx - m, miny - m, maxx + m, maxy + m,
                    380, 280, 14, crosshair=(mx, my))

    # Richtungen (in die Bahn hinein) + Laengen fuer die Umrisse
    (uax, uay), lenA = _unit(e["oxa"] - xa, e["oya"] - ya)
    (ubx, uby), lenB = _unit(e["oxb"] - xb, e["oyb"] - yb)
    rA, rB = e["wa"] / 2.0, e["wb"] / 2.0
    tA = (xa, ya, uax, uay, rA, lenA)
    tB = (xb, yb, ubx, uby, rB, lenB)

    # Zoom-Fenster: beide End-Kreise mit etwas Rand
    rmax = max(rA, rB, 0.0)
    half = max((d * 0.5 + rmax) * 1.35, 0.03)
    zoom = _zoom_svg(lines, tA, tB,
                     mx - half, my - half, mx + half, my + half,
                     320, 300, 14, clip_id=f"clip{idx}")

    return f'''<div class="err" data-dist="{d:.5f}" data-overlap="{e["overlap"]:.2f}">
  <div class="search">
    <code>{esc(search)}</code>
    <button onclick="cp(this)">Kopieren</button>
  </div>
  <div class="dist">Abstand: <b>{d:.4f} mm</b>
     &nbsp;&middot;&nbsp; Ueberlappung: <b>{e["overlap"]:.0f}%</b>
     &nbsp;&middot;&nbsp; {esc(e["kind"])}</div>
  <div class="sub">Width A {e["wa"]:.3f} / B {e["wb"]:.3f} mm &middot;
     quer {e["lat"]:.4f} mm &middot; laengs {e["sep"]:+.4f} mm &middot;
     Excel-Zeilen {e["row_a"]} &harr; {e["row_b"]}</div>
  <div class="graphs">
    <figure>{overview}<figcaption>Uebersicht Gruppe</figcaption></figure>
    <figure>{zoom}<figcaption>Zoom &middot; End-Kreise (r = Width/2), Schnittmenge = Ueberlappung</figcaption></figure>
  </div>
  <div class="status">
    <button class="stbtn" onclick="setState(this,'ignored')">Ignorieren</button>
    <button class="stbtn" onclick="setState(this,'fixed')">Behoben</button>
    <span class="badge"></span>
  </div>
</div>'''


def esc(s):
    return htmllib.escape(str(s), quote=True)


def build_html(real_errors, overlaps, group_lines, total, ng, n_singles, filename):
    """Baut den kompletten HTML-Report."""
    parts = []
    idx = 0
    if real_errors:
        parts.append('<h2 class="sec">Naeherungs-Fehler '
                     f'<span>({len(real_errors)})</span></h2>')
        parts.append('<div class="blocks">')
        for e in real_errors:
            parts.append(_error_block(e, group_lines, idx))
            idx += 1
        parts.append('</div>')
    else:
        parts.append('<p class="ok">Keine Naeherungs-Fehler gefunden.</p>')

    if overlaps:
        parts.append('<h2 class="sec sec-ov">Positive Ueberlappungen &ndash; harmlos '
                     f'<span>({len(overlaps)})</span></h2>')
        parts.append('<p class="hint">Kollineare Bahnen, die ineinander laufen. '
                     'Technisch ein Fehler, elektrisch aber verbunden.</p>')
        parts.append('<div class="blocks">')
        for e in overlaps:
            parts.append(_error_block(e, group_lines, idx))
            idx += 1
        parts.append('</div>')

    body = "\n".join(parts)

    sortbar = ''
    if real_errors or overlaps:
        sortbar = (
            '<div class="sortbar">Sortieren nach:'
            '<button class="sortbtn active" onclick="sortBy(\'dist\',this)">'
            'Abstand &darr; (groesster zuerst)</button>'
            '<button class="sortbtn" onclick="sortBy(\'overlap\',this)">'
            'Ueberlappung &uarr; (kleinste zuerst)</button>'
            '<label style="margin-left:14px"><input type="checkbox" id="hideDone" '
            'onchange="applyFilter()"> erledigte ausblenden</label>'
            '<span class="badge" id="openCount" style="margin-left:auto"></span></div>'
        )

    style = """
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
               align-items: center; }
    .sortbtn { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
               padding: 5px 12px; cursor: pointer; font-size: 13px; color: #384250; }
    .sortbtn:hover { background: #eef0f3; }
    .sortbtn.active { background: #1b1f24; color: #fff; border-color: #1b1f24; }
    main { max-width: 1040px; margin: 0 auto; padding: 20px 16px 60px; }
    .err { background: #fff; border: 1px solid #e3e6ea; border-radius: 10px;
           padding: 16px 18px; margin: 0 0 18px; transition: opacity .15s; }
    .err.ignored { opacity: .5; border-left: 4px solid #97a1af; }
    .err.fixed { opacity: .55; border-left: 4px solid #1a7f37; }
    .search { display: flex; gap: 8px; align-items: stretch; margin-bottom: 10px; }
    .search code { flex: 1; background: #0f1116; color: #e6edf3; border-radius: 6px;
                   padding: 9px 12px; font-size: 13px; overflow-x: auto; white-space: nowrap; }
    .search button { border: 1px solid #c9ced6; background: #fff; border-radius: 6px;
                     padding: 0 14px; cursor: pointer; font-size: 13px; }
    .search button:hover { background: #eef0f3; }
    .dist { font-size: 14px; margin-bottom: 4px; }
    .dist b { color: #c4302b; }
    .sub { font-size: 12px; color: #5f6b7c; margin-bottom: 12px; }
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
    .ok { font-size: 16px; color: #1a7f37; background: #fff; border: 1px solid #e3e6ea;
          border-radius: 10px; padding: 20px; text-align: center; }
    """

    script = """
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
          return key === 'dist' ? bv - av : av - bv;  // Abstand absteigend, Ueberlappung aufsteigend
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
      var next = (cur === state) ? '' : state;   // gleicher Button nochmal -> zuruecksetzen
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
    function applyFilter(){
      var hide = document.getElementById('hideDone');
      hide = hide && hide.checked;
      document.querySelectorAll('.err').forEach(function(e){
        var handled = !!e.getAttribute('data-state');
        e.style.display = (hide && handled) ? 'none' : '';
      });
    }
    function updateCounts(){
      var all = document.querySelectorAll('.err').length;
      var done = document.querySelectorAll('.err[data-state="ignored"], .err[data-state="fixed"]').length;
      var el = document.getElementById('openCount');
      if (el) el.textContent = (all - done) + ' / ' + all + ' offen';
    }
    document.addEventListener('DOMContentLoaded', updateCounts);
    """

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
  <div class="meta">Datei: <b>{esc(filename)}</b> &nbsp;&middot;&nbsp;
    Zeilen: <b>{total}</b> &nbsp;&middot;&nbsp;
    Gruppen: <b>{ng}</b> &nbsp;&middot;&nbsp;
    Einzelpunkte: <b>{n_singles}</b> &nbsp;&middot;&nbsp;
    Fehler: <b>{len(real_errors)}</b> &nbsp;&middot;&nbsp;
    Ueberlappungen: <b>{len(overlaps)}</b></div>
</header>
{sortbar}
<main>
{body}
</main>
<script>{script}</script>
</body>
</html>'''


def main():
    # --- Datei-Explorer ---
    root = tk.Tk()
    root.withdraw()
    path = filedialog.askopenfilename(
        title="Excel mit Linien-Liste auswaehlen",
        filetypes=[("Excel", "*.xlsx *.xlsm *.xls"), ("Alle Dateien", "*.*")],
    )
    if not path:
        print("Keine Datei gewaehlt. Abbruch.")
        return

    print(f"Datei: {path}")

    # --- Spalten anhand der Kopfzeile finden ---
    print("Lese Kopfzeile ...")
    header_df = pd.read_excel(path, nrows=0)
    cols = list(header_df.columns)

    mapping = {}
    for key, hints in COL_HINTS.items():
        col = find_column(cols, hints)
        if col is None:
            sys.exit(f"Spalte fuer '{key}' nicht gefunden.\nVorhandene Spalten: {cols}")
        mapping[key] = col

    print("Erkannte Spalten:")
    for k in ("kind", "layer", "net", "x1", "y1", "x2", "y2", "width"):
        print(f"   {k:6s} -> {mapping[k]}")

    # --- Daten lesen (nur benoetigte Spalten, als Text -> selbst parsen) ---
    use = [mapping[k] for k in ("kind", "layer", "net", "x1", "y1", "x2", "y2", "width")]
    print("Lese Daten (kann bei grossen Dateien etwas dauern) ...")
    df = pd.read_excel(path, usecols=use, dtype=str)
    rows_read = len(df)
    print(f"Zeilen gelesen: {rows_read}")

    # Original-Excel-Zeile pro Datenzeile merken (Kopfzeile = 1, Daten ab 2),
    # damit die Zeilennummern im Report nach dem Filtern noch stimmen.
    df["_excel_row"] = range(2, rows_read + 2)

    # --- Auf Object Kind == FILTER_KIND filtern ---
    kind_series = df[mapping["kind"]].fillna("").astype(str).str.strip().str.lower()
    mask = kind_series == FILTER_KIND.strip().lower()
    df = df[mask].reset_index(drop=True)
    total = len(df)
    print(f"Zeilen mit '{FILTER_KIND}': {total}  (aussortiert: {rows_read - total})")
    if total == 0:
        sys.exit(f"Keine Zeilen mit Object Kind == '{FILTER_KIND}' gefunden. Abbruch.")

    # --- Werte aufbereiten ---
    print("Verarbeite Zahlen ...")
    layers = df[mapping["layer"]].fillna("").astype(str).to_numpy()
    nets = df[mapping["net"]].fillna("").astype(str).to_numpy()
    x1 = df[mapping["x1"]].map(to_float).to_numpy()
    y1 = df[mapping["y1"]].map(to_float).to_numpy()
    x2 = df[mapping["x2"]].map(to_float).to_numpy()
    y2 = df[mapping["y2"]].map(to_float).to_numpy()
    wd = df[mapping["width"]].map(to_float).to_numpy()
    excel_rows = df["_excel_row"].to_numpy()

    # --- Punkte + Linien pro Gruppe aufbauen ---
    print("Baue Punkte pro Gruppe auf ...")
    groups = defaultdict(list)
    group_lines = defaultdict(list)  # (layer,net) -> [(row, x1,y1,x2,y2), ...] fuer die Grafik
    skipped = 0
    for i in range(total):
        g = (layers[i], nets[i])
        wi = wd[i] if wd[i] is not None else 0.0
        er = int(excel_rows[i])  # echte Excel-Zeile als Punkt-ID
        # Punkt-Tupel: (row, x, y, width, other_x, other_y)
        # other_x/other_y = anderer Endpunkt derselben Linie -> ergibt die Bahnrichtung
        if x1[i] is not None and y1[i] is not None:
            groups[g].append((er, x1[i], y1[i], wi, x2[i], y2[i]))
        else:
            skipped += 1
        if x2[i] is not None and y2[i] is not None:
            groups[g].append((er, x2[i], y2[i], wi, x1[i], y1[i]))
        else:
            skipped += 1
        # Linie fuer die Grafik nur speichern, wenn beide Endpunkte gueltig sind
        if None not in (x1[i], y1[i], x2[i], y2[i]):
            group_lines[g].append((er, x1[i], y1[i], x2[i], y2[i], wi))
        if (i + 1) % 10000 == 0:
            print(f"   ... {i + 1}/{total} Zeilen verarbeitet")
    if skipped:
        print(f"Hinweis: {skipped} Punkte ohne gueltige Koordinaten uebersprungen.")

    # --- Analyse pro Gruppe mit Fortschritt ---
    group_keys = list(groups.keys())
    ng = len(group_keys)
    print(f"Gruppen (Layer + Net): {ng}")
    print("Starte Analyse ...")

    real_errors = []  # echte Naeherungs-Fehler
    overlaps = []     # positive Ueberlappungen (harmlos, ans Ende)
    n_singles = 0
    last_pct = -1
    for gi, gkey in enumerate(group_keys):
        singles, errors = process_group(groups[gkey])
        layer, net = gkey
        n_singles += len(singles)

        for pa, pb, dist, thr in errors:
            info = analyze_pair(pa, pb)
            rec = {
                "layer": layer, "net": net,
                "row_a": pa[0], "xa": pa[1], "ya": pa[2],
                "wa": pa[3], "oxa": pa[4], "oya": pa[5],
                "row_b": pb[0], "xb": pb[1], "yb": pb[2],
                "wb": pb[3], "oxb": pb[4], "oyb": pb[5],
                "thr": thr,
            }
            rec.update(info)
            if info["category"] == "overlap":
                overlaps.append(rec)
            else:
                real_errors.append(rec)

        if ng:
            pct = int((gi + 1) * 100 / ng)
            if pct != last_pct and pct % 5 == 0:
                print(f"   Analyse: {pct}%  ({gi + 1}/{ng} Gruppen)")
                last_pct = pct

    # Sortierung: groesster Abstand zuerst (in beiden Kategorien)
    real_errors.sort(key=lambda e: -e["dist"])
    overlaps.sort(key=lambda e: -e["dist"])

    # --- HTML-Report schreiben ---
    print("Erzeuge HTML-Report ...")
    base = os.path.splitext(path)[0]
    out = base + "_check_report.html"
    html = build_html(real_errors, overlaps, group_lines,
                      total, ng, n_singles, os.path.basename(path))
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)

    # --- Zusammenfassung ---
    print("\n================= FERTIG =================")
    print(f"Zeilen gesamt:            {total}")
    print(f"Gruppen (Layer+Net):      {ng}")
    print(f"Partnerlose Einzelpunkte: {n_singles}")
    print(f"NAEHERUNGS-FEHLER:        {len(real_errors)}")
    print(f"Positive Ueberlappungen:  {len(overlaps)}")
    print(f"Report gespeichert:       {out}")
    print("==========================================")

    # Report automatisch im Standard-Browser oeffnen
    try:
        if sys.platform.startswith("win"):
            os.startfile(out)  # type: ignore[attr-defined]
        else:
            webbrowser.open("file://" + os.path.abspath(out))
    except Exception:
        pass

    try:
        messagebox.showinfo(
            "Verbindungs-Check fertig",
            f"Zeilen: {total}\n"
            f"Naeherungs-Fehler: {len(real_errors)}\n"
            f"Positive Ueberlappungen: {len(overlaps)}\n\n"
            f"Report:\n{out}",
        )
    except Exception:
        pass


if __name__ == "__main__":
    main()
