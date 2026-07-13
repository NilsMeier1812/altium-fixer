# Verbindungs-Check für Altium

Prüft Track-Endpunkte (pro Layer + Net) auf Stellen, die eigentlich verbunden
sein sollten, aber knapp danebenliegen, und erzeugt einen HTML-Fehlerbericht.

Zwei Betriebsarten mit **gemeinsamem Analyse-Kern** (`verbindungs_check/core.py`):

| Modus | Skript | Datenquelle | Fixen |
|-------|--------|-------------|-------|
| **Altium-Live** | `check_server.py` | direkt aus Altium (über das `.pas`-Skript) | ein Klick im HTML → live ins Board |
| **Excel-Fallback** | `check_excel.py` | aus Altium exportierte `.xlsx` | nur Vorschau, kein Live-Fix |

Der Fehlerbericht schlägt pro Fehler automatisch einen Fix vor:

- **Schnittpunkt** der beiden verlängerten Geraden → beide Endpunkte dorthin.
- **Mittelpunkt**, wenn die Bahnen exakt gleich verlaufen (kollinear).
- **Unlösbar**, wenn die Bahnen parallel versetzt sind (kein Schnittpunkt).

Der Zielpunkt ist in der Zoom-Grafik **grün markiert** (mit Pfeilen von den
alten Punkten), bevor man klickt.

**Layer wählen:** Der **Top- und der Bottom-Layer werden beim Export
übersprungen** (sie tragen bei großen Boards mit Abstand die meisten Bahnen und
sind hier meist nicht gewollt). Das steht in `altium/VerbindungsCheck.pas` in
`RunVerbindungsCheck` an der Zeile

```
if (Trk.Layer = eTopLayer) or (Trk.Layer = eBottomLayer) then
```

– dort lassen sich weitere Layer ergänzen (`or (Trk.Layer = eMidLayer1)` …) oder
die Bedingung entfernen, um doch alles zu exportieren. Alle **exportierten**
Layer lassen sich im Report zusätzlich über die **Layer-Filterleiste** live
ein-/ausblenden (Checkbox je Layer mit Fehleranzahl, plus „alle"/„keine"); der
„offen"-Zähler zählt nur die eingeblendeten Layer.

> **Große Boards:** Altium-Skripte iterieren einzeln über jedes Objekt – das ist
> langsam. Während `RunVerbindungsCheck` läuft, ist Altium **einige Sekunden bis
> ~1–2 Minuten nicht bedienbar** (ein Hinweis-Dialog kündigt das an). Das ist
> normal, bitte **nicht abbrechen**. Eine Not-Bremse (`MAX_ITER`) verhindert ein
> Endlos-Hängen.

---

## Einmalige Einrichtung

### 1. Python
Python 3.8+ installieren (bei der Windows-Installation **„Add Python to PATH"**
anhaken). Prüfen:

```
python --version
```

Für den **Excel-Modus** zusätzlich:

```
pip install -r requirements.txt
```

Der **Altium-Live-Modus** braucht keine Zusatzpakete.

### 2. Dieses Repo ablegen
Den kompletten Ordner (z. B. nach `C:\Tools\altium-fixer`) legen. Wichtig ist,
dass diese Struktur zusammenbleibt:

```
altium-fixer\
  check_server.py
  check_excel.py
  start_watcher.bat         <- Hintergrund-Watcher (empfohlen, in den Autostart)
  start_server.bat          <- Einmal-Server (Alternative, pro Durchlauf 1 Klick)
  verbindungs_check\        <- Analyse-Kern (nicht umbenennen)
  altium\VerbindungsCheck.pas   <- Skript-Code (zwei Prozeduren)
  altium\VerbindungsCheck.PrjScr
```

> **Formlos, mit Absicht.** Das Altium-Skript hat **kein** Formular, keinen
> Timer und keine `.dfm` – genau diese Konstrukte haben Altium in dieser
> Installation beim Laden eingefroren. Stattdessen gibt es zwei einfache
> Prozeduren: `RunVerbindungsCheck` (Export) und `ApplyFixes` (Fixes
> anwenden). Beide kehren sofort zu Altium zurück, nichts läuft dauerhaft.

**Warum eine `.bat` und eine Datei-Bridge?** Das Altium-DelphiScript in dieser
Installation kennt kein `CreateOleObject` – also **kein HTTP und kein Prozess-
Start** aus Altium heraus. Altium kann den Server folglich **nicht selbst
starten**. Deshalb läuft der Server als Python-Prozess außerhalb, und Altium ↔
Python reden über zwei Dateien im Ordner (`bridge_cmd.txt` / `bridge_ack.txt`).
Der Browser redet ganz normal per HTTP mit Python.

### 2a. Watcher in den Autostart legen (einmalig – danach nur noch Altium)

Damit du im Alltag **ausschließlich in Altium klicken** musst, startet der
Server **einmal beim Windows-Login** und läuft dann im Hintergrund. Er wartet
auf `tracks.json` und öffnet den Report **von selbst**, sobald Altium sie
schreibt.

1. **Win+R** → `shell:startup` → Enter (öffnet den Autostart-Ordner).
2. Rechtsklick → **Neu → Verknüpfung** → als Ziel `start_watcher.bat` wählen.
3. Fertig. Ab dem nächsten Login läuft der Watcher automatisch (ein kleines
   Konsolenfenster; kann minimiert bleiben).

> Sofort testen ohne Neustart: `start_watcher.bat` einmal doppelklicken.
> Ohne Autostart bleibt die Alternative `start_server.bat` (einmal pro
> Durchlauf doppelklicken) – siehe unten.

### 3. Altium-Skript einbinden
1. In Altium: **File → Open** → `altium\VerbindungsCheck.PrjScr` (Skriptprojekt).
2. Alternativ **DXP → Run Script… → Browse** → `altium\VerbindungsCheck.pas`.
3. Zum Prüfen die Prozedur **`RunVerbindungsCheck`** wählen → **OK**.

> **Tipp – `ApplyFixes` auf einen Shortcut legen.** Das Anwenden der Fixes
> ist die zweite Prozedur `ApplyFixes`. Am bequemsten weist du ihr eine
> Tastenkombination zu (**DXP → Customize** bzw. Rechtsklick auf die Toolbar
> → *Customize* → Kategorie *Scripts*), dann genügt nach dem Klicken im
> Browser ein Tastendruck.

Das Skript fragt beim Start nur **einen** Wert ab:
- **Arbeitsordner:** der Ordner mit `check_server.py` + `start_server.bat`,
  z. B. `C:\Tools\altium-fixer` (dort landen auch `tracks.json` und die
  Bridge-Dateien).

> Python-Pfad/Port stehen in `start_server.bat`. Falls `python` nicht im PATH
> ist, dort oben `set PY=C:\Pfad\zu\python.exe` eintragen.

---

## Benutzung (Altium)

Zwei Prozeduren, klar getrennt: **exportieren** (`RunVerbindungsCheck`) und
**anwenden** (`ApplyFixes`).

1. Das gewünschte **`.PcbDoc` öffnen** und das **PCB-Fenster in den Vordergrund**
   holen (aktives Dokument – sonst ist der PCB-Server nicht bereit).
2. **`RunVerbindungsCheck`** ausführen und den Arbeitsordner bestätigen.
   - Liest alle Tracks und schreibt `tracks.json`. Ein kurzer Hinweis-Dialog
     erscheint, dann ist Altium sofort wieder frei.
   - Der Hintergrund-Watcher merkt das in ~1 s und **öffnet den Browser
     automatisch** mit dem Report. (Ohne Watcher: einmal `start_server.bat`
     doppelklicken.)
3. Im Report jeden Fehler prüfen. Passt der grün markierte Zielpunkt, auf
   **„In Altium fixen"** klicken – beliebig viele. Die Blöcke zeigen
   **„wartet – in Altium ApplyFixes ausführen"**.
4. In Altium **`ApplyFixes`** ausführen (am besten per Shortcut, siehe Setup).
   - Alle angeklickten Fixes werden **in einem Rutsch** ins Board übernommen,
     die Ansicht aktualisiert sich.
   - Im Browser wechseln die erledigten Blöcke auf **„Behoben in Altium"**.
   - **`Strg+Z`** macht die ganze Runde rückgängig.
5. Weitere Fehler anklicken → wieder `ApplyFixes`. Für einen frischen Stand
   (nach vielen Änderungen) einfach `RunVerbindungsCheck` erneut ausführen.

Browser ↔ Python läuft lokal über HTTP (`127.0.0.1`), Altium ↔ Python über
Dateien im Arbeitsordner (`bridge_cmd.txt` / `bridge_ack.txt`) – keine
Firewall-Freigabe nötig.

> **Warum nicht vollautomatisch?** Ein „ein Klick im Browser → sofort live"
> bräuchte in Altium eine dauerlaufende Form mit Timer. Genau das fror diese
> Installation ein. Der `ApplyFixes`-Tastendruck ist der robuste Ersatz:
> ein Handgriff pro Fix-Runde, dafür stürzt nichts ab.

---

## Benutzung (Excel-Fallback)

Wenn kein Altium zur Hand ist, sondern nur ein Excel-Export:

```
python check_excel.py               # öffnet einen Datei-Dialog
python check_excel.py C:\pfad\liste.xlsx
```

Erwartete Spalten (Überschriften egal ob „X1" oder „X1 (mm)"):
`Object Kind, Layer, Net, X1, Y1, X2, Y2, Width`. Gewertet werden nur Zeilen
mit `Object Kind = Track`. Der Report landet als `*_check_report.html` neben
der Eingabedatei – mit Fix-**Vorschau**, aber ohne Live-Button.

---

## Konfiguration

In `verbindungs_check/core.py` oben:

- `SNAP_TOLERANCE` (0.01 mm) – ab welchem Abstand zwei Punkte als „verbunden" gelten.
- `ANGLE_TOL_DEG` (8°) – bis zu welchem Winkel Bahnen als kollinear zählen.
- `FILTER_KIND` (`Track`) – welcher Object-Kind gewertet wird.

Das Fehlerkriterium bleibt: Abstand zweier partnerloser Endpunkte liegt
zwischen `SNAP_TOLERANCE` und der **Track-Breite (Width)**. Dadurch ist die
Fix-Distanz implizit begrenzt – es gibt bewusst kein extra Limit.

---

## Tests

```
python tests/test_fixes.py          # ohne pytest lauffähig
# oder
pytest tests/
```

Deckt Schnittpunkt / Mittelpunkt / Unlösbar sowie die Gruppen- und
Partner-Logik ab.

---

## Aufbau

```
verbindungs_check/core.py   Analyse, Fix-Berechnung (compute_fix), HTML/SVG
check_server.py             Server (stdlib): HTTP für Browser + Datei-Bridge zu Altium
                            (--watch = dauerhaft, öffnet Report automatisch)
check_excel.py              Excel-Fallback (pandas/openpyxl + tkinter)
start_watcher.bat           Hintergrund-Watcher (in den Autostart) – Server läuft dauerhaft
start_server.bat            Einmal-Server (Alternative; Altium kann keinen Prozess starten)
altium/VerbindungsCheck.pas DelphiScript (formlos): RunVerbindungsCheck (Export) + ApplyFixes
tests/test_fixes.py         Geometrie- und Analyse-Tests
```

### Protokoll

```
Browser  --POST /fix {fix_id}-->  Server            (HTTP, legt Fix in Queue)
Browser  --GET  /status-------->  Server            (HTTP, Anzeige: wartet/behoben/veraltet)

Server   --schreibt---> bridge_cmd.txt  --liest-->  Altium   (offene Fixes, bei ApplyFixes)
Altium   --schreibt---> bridge_ack.txt  --liest-->  Server   (erledigt: fix_id;1)
```

Grund für die Datei-Bridge: Das Altium-DelphiScript kennt hier kein
`CreateOleObject` (kein HTTP/OLE aus Altium). Datei-I/O geht dagegen zuverlässig.

Track-Identität ohne persistente Referenzen: `RunVerbindungsCheck` vergibt die
ID als **Iterations-Index** über alle Tracks. `ApplyFixes` iteriert das Board in
**derselben Reihenfolge** erneut und rekonstruiert daraus die Zuordnung
ID → Track – deshalb braucht es keine im Speicher gehaltene Form. Wichtig: das
**gleiche PcbDoc** muss aktiv sein und sollte zwischen Export und Anwenden nicht
strukturell verändert werden (Tracks hinzufügen/löschen verschiebt die IDs).

---

## Hinweis zum Altium-Skript

`VerbindungsCheck.pas` kann außerhalb von Altium nicht getestet werden. Es ist
defensiv geschrieben (Fehlerdialoge, `PCBServer`-Prüfung, Board-Prüfung) und
**formlos** – ohne Formular/Timer/`.dfm`, weil genau diese Konstrukte Altium in
dieser Installation beim Laden eingefroren haben. Beim ersten Einsatz empfiehlt
sich ein **kleines Test-Board**: `RunVerbindungsCheck`, im Browser einen Fehler
anklicken, `ApplyFixes`, im Board kontrollieren, `Strg+Z` testen. Je nach
Altium-Version kann eine API-Kleinigkeit abweichen – dann bitte die genaue
Fehlermeldung notieren.
