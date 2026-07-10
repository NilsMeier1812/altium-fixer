#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Verbindungs-Check - Excel-Modus (Fallback ohne Altium).

Liest eine aus Altium exportierte Excel-Liste, analysiert die Track-Endpunkte
und schreibt einen statischen HTML-Report neben die Eingabedatei. Der Report
zeigt die Fix-Vorschlaege inkl. markiertem Zielpunkt, aber ohne Live-Button
(dafuer den Altium-Modus / check_server.py nutzen).

Bedienung:
  python check_excel.py                # Datei-Dialog
  python check_excel.py pfad/zur.xlsx  # ohne Dialog (z.B. zum Testen)

Abhaengigkeiten:
  pip install pandas openpyxl
"""

import os
import sys
import webbrowser

from verbindungs_check.core import (
    analyze_tracks, build_html, find_column, COL_HINTS, FILTER_KIND,
)

try:
    import pandas as pd
except ImportError:
    sys.exit("pandas fehlt. Bitte installieren:  pip install pandas openpyxl")


def read_excel_records(path):
    """Liest die Excel-Datei und liefert (records, meldungen)."""
    msgs = []
    header_df = pd.read_excel(path, nrows=0)
    cols = list(header_df.columns)

    mapping = {}
    for key, hints in COL_HINTS.items():
        col = find_column(cols, hints)
        if col is None:
            sys.exit(f"Spalte fuer '{key}' nicht gefunden.\nVorhandene Spalten: {cols}")
        mapping[key] = col

    msgs.append("Erkannte Spalten: " +
                ", ".join(f"{k}->{mapping[k]}" for k in
                          ("kind", "layer", "net", "x1", "y1", "x2", "y2", "width")))

    use = [mapping[k] for k in ("kind", "layer", "net", "x1", "y1", "x2", "y2", "width")]
    df = pd.read_excel(path, usecols=use, dtype=str)
    rows_read = len(df)
    df["_excel_row"] = range(2, rows_read + 2)

    kind_series = df[mapping["kind"]].fillna("").astype(str).str.strip().str.lower()
    mask = kind_series == FILTER_KIND.strip().lower()
    df = df[mask].reset_index(drop=True)
    total = len(df)
    msgs.append(f"Zeilen mit '{FILTER_KIND}': {total}  (aussortiert: {rows_read - total})")
    if total == 0:
        sys.exit(f"Keine Zeilen mit Object Kind == '{FILTER_KIND}' gefunden. Abbruch.")

    records = []
    for _, row in df.iterrows():
        records.append({
            "id":    int(row["_excel_row"]),   # Excel-Zeile als Track-ID
            "layer": row[mapping["layer"]],
            "net":   row[mapping["net"]],
            "x1":    row[mapping["x1"]],
            "y1":    row[mapping["y1"]],
            "x2":    row[mapping["x2"]],
            "y2":    row[mapping["y2"]],
            "width": row[mapping["width"]],
        })
    return records, msgs


def main():
    path = None
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        try:
            import tkinter as tk
            from tkinter import filedialog, messagebox
            root = tk.Tk()
            root.withdraw()
            path = filedialog.askopenfilename(
                title="Excel mit Linien-Liste auswaehlen",
                filetypes=[("Excel", "*.xlsx *.xlsm *.xls"), ("Alle Dateien", "*.*")],
            )
        except Exception as ex:
            sys.exit(f"Kein Datei-Dialog moeglich ({ex}). "
                     f"Bitte Pfad als Argument uebergeben.")

    if not path:
        print("Keine Datei gewaehlt. Abbruch.")
        return

    print(f"Datei: {path}")
    records, msgs = read_excel_records(path)
    for m in msgs:
        print(m)

    print("Analysiere ...")
    real_errors, overlaps, group_lines, stats = analyze_tracks(records)

    base = os.path.splitext(path)[0]
    out = base + "_check_report.html"
    html = build_html(real_errors, overlaps, group_lines, stats,
                      os.path.basename(path), server_mode=False)
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)

    print("\n================= FERTIG =================")
    print(f"Tracks gesamt:            {stats['total']}")
    print(f"Gruppen (Layer+Net):      {stats['groups']}")
    print(f"Partnerlose Einzelpunkte: {stats['singles']}")
    print(f"NAEHERUNGS-FEHLER:        {len(real_errors)}")
    print(f"Positive Ueberlappungen:  {len(overlaps)}")
    print(f"Report gespeichert:       {out}")
    print("==========================================")

    try:
        if sys.platform.startswith("win"):
            os.startfile(out)  # type: ignore[attr-defined]
        else:
            webbrowser.open("file://" + os.path.abspath(out))
    except Exception:
        pass

    try:
        from tkinter import messagebox
        messagebox.showinfo(
            "Verbindungs-Check fertig",
            f"Tracks: {stats['total']}\n"
            f"Naeherungs-Fehler: {len(real_errors)}\n"
            f"Positive Ueberlappungen: {len(overlaps)}\n\n"
            f"Report:\n{out}",
        )
    except Exception:
        pass


if __name__ == "__main__":
    main()
