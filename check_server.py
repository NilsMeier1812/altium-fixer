#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Verbindungs-Check - Altium-Live-Modus (Server).

Wird vom Altium-Skript gestartet:
    python check_server.py <tracks.json> [--port 8765] [--no-open]

Ablauf:
  1. Liest tracks.json (Liste von Track-Records, aus Altium exportiert).
  2. Analysiert und baut den HTML-Report (Server-Variante mit Fix-Buttons).
  3. Startet einen lokalen HTTP-Server (nur 127.0.0.1) und oeffnet den Browser.
  4. Klickt der User "In Altium fixen", landet das Kommando in einer Queue.
  5. Das Altium-Skript pollt GET /pending, setzt die Koordinaten und meldet
     Erfolg per GET /ack zurueck. GET /status treibt die Anzeige im Browser.

Protokoll (bewusst primitiv, damit DelphiScript kein JSON parsen muss):
  GET  /                     -> HTML-Report
  GET  /status               -> JSON {states:{fix_id:state}, stale:[...]}
  POST /fix   {fix_id:"..."} -> Fix in die Queue legen
  GET  /pending              -> Textzeilen "fix_id;track_id;end;x_mm;y_mm"
                                (nur neue; setzt sie auf 'pending')
  GET  /ack?fix_id=..&ok=1   -> Fix als erledigt/fehlgeschlagen markieren

Reine Standardbibliothek.

tracks.json-Format:
  {
    "document": "Board1.PcbDoc",         (optional, nur Anzeige)
    "tracks": [
      {"id":0,"layer":"Top Layer","net":"GND",
       "x1":1.0,"y1":2.0,"x2":3.0,"y2":2.0,"width":0.25},
      ...
    ]
  }
"""

import os
import sys
import json
import argparse
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verbindungs_check.core import analyze_tracks, build_html  # noqa: E402


class FixRegistry:
    """Haelt Fix-Kommandos, Zustaende und die Queue - threadsicher."""

    def __init__(self, real_errors, overlaps):
        self.lock = threading.Lock()
        # fix_id -> moves [(track_id, end, tx, ty), ...]
        self.moves = {}
        # fix_id -> set of track_ids (fuer Stale-Erkennung)
        self.tracks_of = {}
        self.state = {}   # fix_id -> queued|pending|done|failed
        self.done_tracks = set()  # Tracks, die bereits gefixt wurden

        for e in list(real_errors) + list(overlaps):
            fid = e["fix_id"]
            fix = e["fix"]
            if fix["status"] == "unsolvable" or not fix["moves"]:
                continue
            self.moves[fid] = list(fix["moves"])
            self.tracks_of[fid] = {m[0] for m in fix["moves"]}

    def enqueue(self, fid):
        with self.lock:
            if fid not in self.moves:
                return False, "unbekannte Fix-ID"
            st = self.state.get(fid)
            if st in ("queued", "pending"):
                return True, "bereits in Bearbeitung"
            if st == "done":
                return True, "bereits erledigt"
            self.state[fid] = "queued"
            return True, "ok"

    def take_pending(self):
        """Liefert Textzeilen fuer alle 'queued' Fixes und setzt sie auf 'pending'."""
        out = []
        with self.lock:
            for fid, st in list(self.state.items()):
                if st == "queued":
                    for (tid, end, tx, ty) in self.moves[fid]:
                        out.append(f"{fid};{tid};{end};{tx:.6f};{ty:.6f}")
                    self.state[fid] = "pending"
        return "\n".join(out)

    def ack(self, fid, ok):
        with self.lock:
            if fid not in self.moves:
                return False
            if ok:
                self.state[fid] = "done"
                self.done_tracks |= self.tracks_of.get(fid, set())
            else:
                self.state[fid] = "failed"
            return True

    def snapshot(self):
        """Zustaende + Liste veralteter Fixes (referenzieren gefixte Tracks)."""
        with self.lock:
            states = dict(self.state)
            stale = []
            for fid, tset in self.tracks_of.items():
                if self.state.get(fid) == "done":
                    continue
                if tset & self.done_tracks:
                    stale.append(fid)
            return {"states": states, "stale": stale}


def make_handler(html_bytes, registry):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # keine Konsolen-Spam

        def _send(self, code, ctype, body):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/" or u.path == "/index.html":
                self._send(200, "text/html; charset=utf-8", html_bytes)
            elif u.path == "/status":
                self._send(200, "application/json",
                           json.dumps(registry.snapshot()))
            elif u.path == "/pending":
                self._send(200, "text/plain; charset=utf-8",
                           registry.take_pending())
            elif u.path == "/ack":
                q = parse_qs(u.query)
                fid = (q.get("fix_id") or [""])[0]
                ok = (q.get("ok") or ["1"])[0] == "1"
                good = registry.ack(fid, ok)
                self._send(200 if good else 404, "text/plain",
                           "ok" if good else "unknown")
            elif u.path == "/ping":
                self._send(200, "text/plain", "pong")
            else:
                self._send(404, "text/plain", "not found")

        def do_POST(self):
            u = urlparse(self.path)
            if u.path == "/fix":
                length = int(self.headers.get("Content-Length", 0) or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    data = json.loads(raw.decode("utf-8")) if raw else {}
                    fid = str(data.get("fix_id", ""))
                except (ValueError, UnicodeDecodeError):
                    self._send(400, "application/json",
                               json.dumps({"ok": False, "error": "bad json"}))
                    return
                ok, msg = registry.enqueue(fid)
                self._send(200, "application/json",
                           json.dumps({"ok": ok, "error": None if ok else msg,
                                       "msg": msg}))
            else:
                self._send(404, "text/plain", "not found")

    return Handler


def load_tracks(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        return {"document": os.path.basename(path), "tracks": data}
    data.setdefault("document", os.path.basename(path))
    data.setdefault("tracks", [])
    return data


def start_server(port, handler_cls, max_tries=25):
    """Startet den Server, bei belegtem Port hochzaehlen."""
    for i in range(max_tries):
        p = port + i
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", p), handler_cls)
            return srv, p
        except OSError:
            continue
    raise RuntimeError(f"Kein freier Port ab {port} gefunden.")


def main():
    ap = argparse.ArgumentParser(description="Verbindungs-Check Altium-Live-Server")
    ap.add_argument("tracks", help="Pfad zur tracks.json")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true", help="Browser nicht oeffnen")
    args = ap.parse_args()

    data = load_tracks(args.tracks)
    doc = data.get("document", "Altium")
    tracks = data.get("tracks", [])
    print(f"Dokument: {doc}  ({len(tracks)} Tracks)")

    print("Analysiere ...")
    real_errors, overlaps, group_lines, stats = analyze_tracks(tracks)
    print(f"Fehler: {len(real_errors)}  Ueberlappungen: {len(overlaps)}")

    html = build_html(real_errors, overlaps, group_lines, stats, doc,
                      server_mode=True)
    html_bytes = html.encode("utf-8")

    registry = FixRegistry(real_errors, overlaps)
    handler = make_handler(html_bytes, registry)
    srv, port = start_server(args.port, handler)
    url = f"http://127.0.0.1:{port}/"

    # Tatsaechlichen Port neben die tracks.json schreiben, damit das
    # Altium-Skript ihn findet (falls der Wunsch-Port belegt war).
    try:
        with open(args.tracks + ".port", "w", encoding="utf-8") as pf:
            pf.write(str(port))
    except OSError:
        pass

    print(f"Server laeuft auf {url}")
    print("Altium-Skript pollt /pending  |  Beenden mit Strg+C")

    if not args.no_open:
        try:
            webbrowser.open(url)
        except Exception:
            pass

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nBeendet.")
        srv.shutdown()


if __name__ == "__main__":
    main()
