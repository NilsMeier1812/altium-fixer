"""Verbindungs-Check Kern (Analyse, Fix-Berechnung, HTML-Report).

Reine Standardbibliothek - keine externen Abhaengigkeiten. So kann der
Altium-Server-Modus (check_server.py) ohne pandas/openpyxl laufen; nur der
Excel-Modus (check_excel.py) braucht zusaetzlich pandas.
"""

from .core import (
    analyze_tracks,
    build_html,
    compute_fix,
    to_float,
    SNAP_TOLERANCE,
    ANGLE_TOL_DEG,
    FILTER_KIND,
)

__all__ = [
    "analyze_tracks",
    "build_html",
    "compute_fix",
    "to_float",
    "SNAP_TOLERANCE",
    "ANGLE_TOL_DEG",
    "FILTER_KIND",
]
