#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Verbindungs-Check - Altium-Live-Modus (Server).

Zwei Startarten:

  1. Einmal-Modus (wie bisher):
        python check_server.py <tracks.json> [--port 8765] [--no-open]
     Liest genau eine tracks.json, baut den Report, serviert ihn, fertig.

  2. Watch-Modus (dauerhaft im Hintergrund, empfohlen fuer Altium):
        python check_server.py --watch <arbeitsordner> [--port 8765]
     Startet OHNE tracks.json und wartet. Sobald Altium <ordner>\\tracks.json
     schreibt, baut der Server den Report neu und oeffnet den Browser von
     selbst. So muss man im Alltag NUR in Altium klicken - der Server laeuft
     schon (z.B. per Autostart-Verknuepfung auf start_watcher.bat).

Warum ueberhaupt ein Server + Datei-Bridge?
  Das Altium-DelphiScript kennt hier kein CreateOleObject: kein HTTP und kein
  Prozess-Start aus Altium heraus. Deshalb kann Altium den Server NICHT selbst
  starten. Der Browser dagegen redet ganz normal per HTTP mit Python; Altium
  redet mit Python ueber zwei Dateien (bridge_cmd.txt / bridge_ack.txt).

Protokoll (bewusst primitiv, damit DelphiScript kein JSON parsen muss):
  GET  /                     -> HTML-Report (aktueller Stand)
  GET  /status               -> JSON {states:{fix_id:state}, stale:[...], gen:N}
  POST /fix   {fix_id:"..."} -> Fix in die Queue legen
  bridge_cmd.txt  (Datei)    -> offene Fixes "fix_id;track;end;x;y"
  bridge_ack.txt  (Datei)    -> Bestaetigungen "fix_id;1"

Reine Standardbibliothek.
"""

import os
import sys
import json
import time
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
        self.state = {}   # fix_id -> queued|sent|pending|done|failed
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
            if st in ("queued", "sent", "pending"):
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

    def bridge_lines(self):
        """
        Textzeilen fuer alle noch offenen Fixes (Datei-Bridge zu Altium).
        Format je Endpunkt: fix_id;track_id;end;x_mm;y_mm
        'queued' wird dabei auf 'sent' gesetzt (im Browser: 'wartet auf Altium').
        """
        out = []
        with self.lock:
            for fid, st in list(self.state.items()):
                if st in ("done", "failed"):
                    continue
                if st == "queued":
                    self.state[fid] = "sent"
                for (tid, end, tx, ty) in self.moves[fid]:
                    out.append(f"{fid};{tid};{end};{tx:.6f};{ty:.6f}")
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


class AppState:
    """
    Gemeinsamer, veraenderbarer Zustand fuer HTTP-Handler, Bridge und Watcher.
    Im Watch-Modus tauscht der Watcher html_bytes + registry bei jeder neuen
    tracks.json aus. 'gen' zaehlt hoch, damit der Browser einen Reload erkennt.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.gen = 0
        self.doc = ""
        self.registry = None
        self.html_bytes = _waiting_html().encode("utf-8")

    def set_report(self, html_bytes, registry, doc):
        with self.lock:
            self.gen += 1
            self.html_bytes = html_bytes
            self.registry = registry
            self.doc = doc
            return self.gen

    def get_html(self):
        with self.lock:
            return self.html_bytes

    def get_registry(self):
        with self.lock:
            return self.registry

    def get_gen(self):
        with self.lock:
            return self.gen


def _waiting_html():
    return (
        "<!doctype html><html lang='de'><head><meta charset='utf-8'>"
        "<meta http-equiv='refresh' content='2'>"
        "<title>Verbindungs-Check - wartet</title>"
        "<style>body{font-family:Segoe UI,Arial,sans-serif;background:#0f172a;"
        "color:#e2e8f0;display:flex;align-items:center;justify-content:center;"
        "height:100vh;margin:0}div{text-align:center;max-width:32rem;line-height:1.5}"
        "h1{font-size:1.4rem}code{background:#1e293b;padding:.1rem .35rem;"
        "border-radius:.25rem}</style></head><body><div>"
        "<h1>Warte auf Altium&nbsp;&hellip;</h1>"
        "<p>Der Server laeuft. Starte in Altium <code>RunVerbindungsCheck</code> "
        "&ndash; sobald <code>tracks.json</code> geschrieben ist, erscheint der "
        "Report hier automatisch.</p></div></body></html>"
    )


def make_handler(state):
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
                self._send(200, "text/html; charset=utf-8", state.get_html())
            elif u.path == "/status":
                reg = state.get_registry()
                snap = reg.snapshot() if reg else {"states": {}, "stale": []}
                snap["gen"] = state.get_gen()
                self._send(200, "application/json", json.dumps(snap))
            elif u.path == "/pending":
                reg = state.get_registry()
                self._send(200, "text/plain; charset=utf-8",
                           reg.take_pending() if reg else "")
            elif u.path == "/ack":
                reg = state.get_registry()
                q = parse_qs(u.query)
                fid = (q.get("fix_id") or [""])[0]
                ok = (q.get("ok") or ["1"])[0] == "1"
                good = reg.ack(fid, ok) if reg else False
                self._send(200 if good else 404, "text/plain",
                           "ok" if good else "unknown")
            elif u.path == "/ping":
                self._send(200, "text/plain", "pong")
            else:
                self._send(404, "text/plain", "not found")

        def do_POST(self):
            u = urlparse(self.path)
            if u.path == "/fix":
                reg = state.get_registry()
                length = int(self.headers.get("Content-Length", 0) or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    data = json.loads(raw.decode("utf-8")) if raw else {}
                    fid = str(data.get("fix_id", ""))
                except (ValueError, UnicodeDecodeError):
                    self._send(400, "application/json",
                               json.dumps({"ok": False, "error": "bad json"}))
                    return
                if not reg:
                    self._send(200, "application/json",
                               json.dumps({"ok": False, "error": "kein Report geladen",
                                           "msg": "kein Report geladen"}))
                    return
                ok, msg = reg.enqueue(fid)
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


def build_report(path):
    """tracks.json -> (html_bytes, registry, doc). Kann Exceptions werfen."""
    data = load_tracks(path)
    doc = data.get("document", "Altium")
    tracks = data.get("tracks", [])
    real_errors, overlaps, group_lines, stats = analyze_tracks(tracks)
    html = build_html(real_errors, overlaps, group_lines, stats, doc,
                      server_mode=True)
    registry = FixRegistry(real_errors, overlaps)
    return html.encode("utf-8"), registry, doc, len(tracks), \
        len(real_errors), len(overlaps)


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


def clear_bridge(cmd_path, ack_path):
    for p in (cmd_path, ack_path):
        try:
            if os.path.exists(p):
                os.remove(p)
        except OSError:
            pass


def bridge_loop(state, cmd_path, ack_path, stop_event):
    """
    Datei-Bridge zu Altium (weil Altium-DelphiScript hier kein OLE/HTTP kann):
      - schreibt offene Fixes nach bridge_cmd.txt  (Server -> Altium)
      - liest Bestaetigungen aus bridge_ack.txt     (Altium -> Server)
    Bezieht die aktuelle Registry immer frisch aus AppState, damit ein Reload
    (neue tracks.json im Watch-Modus) sauber uebernommen wird.
    """
    cur_reg = None
    processed = set()
    while not stop_event.is_set():
        reg = state.get_registry()

        # Registry gewechselt (neuer Report) -> Ack-Dedupe zuruecksetzen
        if reg is not cur_reg:
            cur_reg = reg
            processed = set()

        if reg is not None:
            # 1) offene Fixes rausschreiben (atomar via temp + replace)
            try:
                body = reg.bridge_lines()
                tmp = cmd_path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(body)
                os.replace(tmp, cmd_path)
            except OSError:
                pass

            # 2) Bestaetigungen einlesen (Zeilen "fix_id;ok")
            try:
                if os.path.exists(ack_path):
                    with open(ack_path, "r", encoding="utf-8") as f:
                        lines = f.read().splitlines()
                    for ln in lines:
                        ln = ln.strip()
                        if not ln or ";" not in ln:
                            continue
                        fid, ok = ln.split(";", 1)
                        fid = fid.strip()
                        if fid in processed:
                            continue
                        processed.add(fid)
                        good = ok.strip() in ("1", "ok", "OK", "true", "True")
                        reg.ack(fid, good)
            except OSError:
                pass

        time.sleep(0.3)


def _stable_stat(path):
    """(mtime, size) der Datei oder None, wenn sie (gerade) nicht lesbar ist."""
    try:
        st = os.stat(path)
        return (st.st_mtime, st.st_size)
    except OSError:
        return None


def watch_loop(state, json_path, cmd_path, ack_path, url, open_browser,
               stop_event):
    """
    Ueberwacht json_path. Bei einer neuen/geaenderten (und fertig geschriebenen)
    tracks.json wird der Report neu gebaut, die Bridge zurueckgesetzt und der
    Browser geoeffnet. So genuegt im Alltag ein Klick in Altium.
    """
    last_sig = None
    while not stop_event.is_set():
        sig = _stable_stat(json_path)
        if sig is not None and sig != last_sig:
            # kurz warten und pruefen, ob die Datei fertig geschrieben ist
            time.sleep(0.4)
            sig2 = _stable_stat(json_path)
            if sig2 is None or sig2 != sig:
                continue  # noch im Schreibvorgang -> naechste Runde
            try:
                html_bytes, registry, doc, ntr, nerr, nov = build_report(json_path)
            except (ValueError, OSError, KeyError) as ex:
                # unvollstaendige/kaputte Datei -> nochmal versuchen
                print(f"tracks.json noch nicht auswertbar ({ex}); warte ...")
                time.sleep(0.5)
                continue
            last_sig = sig2
            clear_bridge(cmd_path, ack_path)   # frische Sitzung
            gen = state.set_report(html_bytes, registry, doc)
            print(f"[#{gen}] Neuer Report: {doc}  "
                  f"({ntr} Tracks, {nerr} Fehler, {nov} Ueberlappungen)")
            if open_browser:
                try:
                    webbrowser.open(url)
                except Exception:
                    pass
        time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser(description="Verbindungs-Check Altium-Live-Server")
    ap.add_argument("target", nargs="?",
                    help="Pfad zur tracks.json (Einmal-Modus) ODER "
                         "Arbeitsordner (mit --watch)")
    ap.add_argument("--watch", action="store_true",
                    help="Dauerhaft laufen und auf tracks.json im Ordner warten")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true", help="Browser nicht oeffnen")
    args = ap.parse_args()

    state = AppState()
    handler = make_handler(state)
    srv, port = start_server(args.port, handler)
    url = f"http://127.0.0.1:{port}/"

    stop_event = threading.Event()

    if args.watch:
        # ----- Watch-Modus: Ordner ueberwachen, wartet auf Altium -----
        workdir = os.path.abspath(args.target or ".")
        if not os.path.isdir(workdir):
            print(f"Ordner nicht gefunden: {workdir}")
            sys.exit(1)
        json_path = os.path.join(workdir, "tracks.json")
        cmd_path = os.path.join(workdir, "bridge_cmd.txt")
        ack_path = os.path.join(workdir, "bridge_ack.txt")
        clear_bridge(cmd_path, ack_path)

        # falls schon eine tracks.json daliegt: gleich laden
        if os.path.exists(json_path):
            try:
                html_bytes, registry, doc, ntr, nerr, nov = build_report(json_path)
                state.set_report(html_bytes, registry, doc)
                print(f"Vorhandene tracks.json geladen: {doc}  "
                      f"({ntr} Tracks, {nerr} Fehler, {nov} Ueberlappungen)")
            except (ValueError, OSError, KeyError):
                pass

        threading.Thread(target=bridge_loop,
                         args=(state, cmd_path, ack_path, stop_event),
                         daemon=True).start()
        threading.Thread(target=watch_loop,
                         args=(state, json_path, cmd_path, ack_path, url,
                               not args.no_open, stop_event),
                         daemon=True).start()

        print(f"Watch-Modus aktiv. Ordner: {workdir}")
        print(f"Server: {url}")
        print("Laeuft im Hintergrund. In Altium 'RunVerbindungsCheck' starten - "
              "der Browser oeffnet dann automatisch. Beenden mit Strg+C.")
    else:
        # ----- Einmal-Modus: genau eine tracks.json -----
        if not args.target:
            print("Bitte tracks.json angeben oder --watch <ordner> nutzen.")
            sys.exit(2)
        json_path = os.path.abspath(args.target)
        workdir = os.path.dirname(json_path)
        cmd_path = os.path.join(workdir, "bridge_cmd.txt")
        ack_path = os.path.join(workdir, "bridge_ack.txt")
        clear_bridge(cmd_path, ack_path)

        html_bytes, registry, doc, ntr, nerr, nov = build_report(json_path)
        state.set_report(html_bytes, registry, doc)
        print(f"Dokument: {doc}  ({ntr} Tracks)")
        print(f"Fehler: {nerr}  Ueberlappungen: {nov}")

        threading.Thread(target=bridge_loop,
                         args=(state, cmd_path, ack_path, stop_event),
                         daemon=True).start()

        print(f"Server laeuft auf {url}")
        print(f"Datei-Bridge: {cmd_path}")
        print("Im Browser fixen -> Altium uebernimmt live. Beenden mit Strg+C.")
        if not args.no_open:
            try:
                webbrowser.open(url)
            except Exception:
                pass

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nBeendet.")
        stop_event.set()
        srv.shutdown()


if __name__ == "__main__":
    main()
