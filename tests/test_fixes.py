# -*- coding: utf-8 -*-
"""Tests fuer die Fix-Geometrie und die Analyse. Reine Standardbibliothek."""

import os
import sys
import math

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from verbindungs_check.core import compute_fix, analyze_tracks  # noqa: E402


def _rec(xa, ya, oxa, oya, xb, yb, oxb, oyb):
    return {
        "track_a": 0, "end_a": 1, "xa": xa, "ya": ya, "oxa": oxa, "oya": oya,
        "track_b": 1, "end_b": 1, "xb": xb, "yb": yb, "oxb": oxb, "oyb": oyb,
    }


def test_intersection():
    # Bahn A horizontal (y=0), Bahn B vertikal (x=0) -> Schnittpunkt (0,0)
    rec = _rec(0.1, 0.0, 10.0, 0.0,   0.0, 0.1, 0.0, 10.0)
    fix = compute_fix(rec)
    assert fix["status"] == "intersection"
    assert abs(fix["tx"] - 0.0) < 1e-9
    assert abs(fix["ty"] - 0.0) < 1e-9
    # Zwei Moves auf denselben Zielpunkt (jetzt mit Original-Koordinaten + Layer)
    assert len(fix["moves"]) == 2
    for m in fix["moves"]:
        tid, end, tx, ty, ox, oy, layer = m
        assert abs(tx) < 1e-9 and abs(ty) < 1e-9


def test_midpoint_collinear():
    # Beide auf y=0, entgegengesetzte Richtungen -> Mittelpunkt
    rec = _rec(0.0, 0.0, -10.0, 0.0,   0.2, 0.0, 10.2, 0.0)
    fix = compute_fix(rec)
    assert fix["status"] == "midpoint"
    assert abs(fix["tx"] - 0.1) < 1e-9
    assert abs(fix["ty"] - 0.0) < 1e-9


def test_unsolvable_parallel_offset():
    # Parallel mit Querversatz 0.2 mm -> kein Schnittpunkt
    rec = _rec(0.0, 0.0, 10.0, 0.0,   0.1, 0.2, 10.1, 0.2)
    fix = compute_fix(rec)
    assert fix["status"] == "unsolvable"
    assert fix["tx"] is None
    assert fix["moves"] == []


def test_far_intersection_still_returned():
    # Fast parallel: Schnittpunkt weit weg, aber vorhanden -> intersection (kein Limit)
    rec = _rec(0.0, 0.0, 10.0, 0.0,   0.0, 0.1, 10.0, 0.1001)
    fix = compute_fix(rec)
    assert fix["status"] == "intersection"
    assert fix["tx"] is not None


def test_analyze_finds_corner_error():
    records = [
        {"id": 0, "layer": "Top", "net": "GND",
         "x1": 0.1, "y1": 0.0, "x2": 10.0, "y2": 0.0, "width": 0.5},
        {"id": 1, "layer": "Top", "net": "GND",
         "x1": 0.0, "y1": 0.1, "x2": 0.0, "y2": 10.0, "width": 0.5},
    ]
    real_errors, overlaps, group_lines, stats = analyze_tracks(records)
    assert len(real_errors) == 1
    e = real_errors[0]
    assert abs(e["dist"] - math.hypot(0.1, 0.1)) < 1e-6
    assert e["fix"]["status"] == "intersection"
    assert abs(e["fix"]["tx"]) < 1e-9 and abs(e["fix"]["ty"]) < 1e-9
    # Moves referenzieren beide Tracks
    tids = {m[0] for m in e["fix"]["moves"]}
    assert tids == {0, 1}
    # ... und tragen Original-Lage + Layer (Basis fuer die raeumliche Suche in Altium)
    for m in e["fix"]["moves"]:
        tid, end, tx, ty, ox, oy, layer = m
        assert layer == "Top"
    by_track = {m[0]: m for m in e["fix"]["moves"]}
    # Track 0: bewegter Endpunkt war (0.1, 0.0); Track 1: (0.0, 0.1)
    assert abs(by_track[0][4] - 0.1) < 1e-9 and abs(by_track[0][5] - 0.0) < 1e-9
    assert abs(by_track[1][4] - 0.0) < 1e-9 and abs(by_track[1][5] - 0.1) < 1e-9


def test_analyze_connected_no_error():
    # Endpunkte exakt aufeinander -> verbunden -> kein Fehler
    records = [
        {"id": 0, "layer": "Top", "net": "GND",
         "x1": 0.0, "y1": 0.0, "x2": 10.0, "y2": 0.0, "width": 0.5},
        {"id": 1, "layer": "Top", "net": "GND",
         "x1": 0.0, "y1": 0.0, "x2": 0.0, "y2": 10.0, "width": 0.5},
    ]
    real_errors, overlaps, group_lines, stats = analyze_tracks(records)
    assert len(real_errors) == 0


def test_groups_isolated_by_net():
    # Gleiche Geometrie, aber verschiedene Netze -> kein Fehler ueber Netz-Grenze
    records = [
        {"id": 0, "layer": "Top", "net": "GND",
         "x1": 0.1, "y1": 0.0, "x2": 10.0, "y2": 0.0, "width": 0.5},
        {"id": 1, "layer": "Top", "net": "VCC",
         "x1": 0.0, "y1": 0.1, "x2": 0.0, "y2": 10.0, "width": 0.5},
    ]
    real_errors, overlaps, group_lines, stats = analyze_tracks(records)
    assert len(real_errors) == 0


if __name__ == "__main__":
    # Ohne pytest lauffaehig
    import traceback
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    ok = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
            ok += 1
        except Exception:
            print(f"FAIL {fn.__name__}")
            traceback.print_exc()
    print(f"\n{ok}/{len(fns)} Tests bestanden")
    sys.exit(0 if ok == len(fns) else 1)
