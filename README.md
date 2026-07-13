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

**Layer wählen:** Es werden immer alle Layer exportiert und geprüft. Im Report
gibt es oben eine **Layer-Filterleiste** (Checkbox je Layer mit Fehleranzahl,
plus „alle"/„keine") – damit blendet man Layer live ein/aus, ohne neu zu
exportieren. Der „offen"-Zähler zählt nur die eingeblendeten Layer.

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
  altium\VerbindungsCheck.pas   <- Skript-Code
  altium\VerbindungsCheck.dfm   <- Formular (gehört zwingend dazu!)
  altium\VerbindungsCheck.PrjScr
```

> **Wichtig:** `.pas` und `.dfm` müssen zusammen im selben Ordner liegen und
> gleich heißen. Das Formular (mit Timer) ist der Grund, warum die Live-
> Übernahme läuft, ohne Altium einzufrieren.

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
1. In Altium: **File → Open** → `altium\VerbindungsCheck.PrjScr` (das Skript-
   projekt öffnen – so werden `.pas` und `.dfm` als Paar geladen).
2. Alternativ **DXP → Run Script… → Browse** → `altium\VerbindungsCheck.pas`
   (die `.dfm` daneben wird automatisch mitgeladen).
3. Die Prozedur **`RunVerbindungsCheck`** wählen → **OK**.

Das Skript fragt beim Start nur **einen** Wert ab:
- **Arbeitsordner:** der Ordner mit `check_server.py` + `start_server.bat`,
  z. B. `C:\Tools\altium-fixer` (dort landen auch `tracks.json` und die
  Bridge-Dateien).

> Python-Pfad/Port stehen in `start_server.bat`. Falls `python` nicht im PATH
> ist, dort oben `set PY=C:\Pfad\zu\python.exe` eintragen.

---

## Benutzung (Altium-Live)

**Mit Watcher im Autostart (empfohlen) – nur noch Altium-Klicks:**

1. Das gewünschte **`.PcbDoc` öffnen und aktiv** haben.
2. Skript starten (`RunVerbindungsCheck`) und den Arbeitsordner bestätigen.
   - Das Skript liest alle Tracks, schreibt `tracks.json` und öffnet ein
     **kleines Status-Fenster** in Altium.
   - Der Hintergrund-Watcher merkt das in ~1 s und **öffnet den Browser
     automatisch** mit dem Report. (Kein `.bat`-Klick nötig.)

**Ohne Watcher (Alternative mit `start_server.bat`):** Statt auf den Watcher zu
warten, nach `RunVerbindungsCheck` einmal `start_server.bat` im Ordner
doppelklicken – der Browser öffnet dann den Report. Danach identisch weiter.

Weiter (beide Varianten):

3. Im Report jeden Fehler prüfen. Passt der grün markierte Zielpunkt, auf
   **„In Altium fixen"** klicken.
   - Der Endpunkt wandert **innerhalb ~1 Sekunde** im Board an die richtige Stelle
     (der Altium-Timer holt den Fix aus der Bridge-Datei).
   - Der Block wechselt auf **„Behoben in Altium"**.
   - Jeder Fix ist ein eigener **Undo-Schritt** in Altium (`Strg+Z`).
4. Betrifft ein späterer Fix einen schon geänderten Track, wird der Block als
   **veraltet** markiert – dann einfach den Check neu starten für den
   aktuellen Stand.
5. **Zum Beenden:** im Altium-Status-Fenster **„Stoppen/Schließen"** klicken.
   Den Watcher (bzw. das Python-Fenster) kannst du laufen lassen – beim nächsten
   `RunVerbindungsCheck` ist er sofort wieder bereit.

Während des Live-Fixens ist das kleine Status-Fenster in Altium offen; ein Timer
darin liest die Bridge-Datei und aktualisiert das Board bei jedem Fix. Altium
bleibt dabei bedienbar (der Timer blockiert nicht). Browser ↔ Python läuft lokal
über HTTP (`127.0.0.1`), Altium ↔ Python über Dateien – keine Firewall-Freigabe
nötig.

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
altium/VerbindungsCheck.pas DelphiScript: Export + Live-Fix über Datei-Bridge
altium/VerbindungsCheck.dfm Formular (Status + Stopp-Button + Timer)
tests/test_fixes.py         Geometrie- und Analyse-Tests
```

### Protokoll

```
Browser  --POST /fix {fix_id}-->  Server            (HTTP, legt Fix in Queue)
Browser  --GET  /status-------->  Server            (HTTP, Anzeige: wartet/behoben/veraltet)

Server   --schreibt---> bridge_cmd.txt  --liest-->  Altium   (offene Fixes)
Altium   --schreibt---> bridge_ack.txt  --liest-->  Server   (erledigt: fix_id;1)
```

Grund für die Datei-Bridge: Das Altium-DelphiScript kennt hier kein
`CreateOleObject` (kein HTTP/OLE aus Altium). Datei-I/O geht dagegen zuverlässig.

Das Altium-Skript identifiziert Tracks **nicht** über Koordinaten, sondern hält
die Track-Referenzen im Speicher (Index = exportierte ID). Fixes werden nur
angewendet, solange das ursprüngliche Dokument aktiv ist.

---

## Hinweis zum Altium-Skript

`VerbindungsCheck.pas` kann außerhalb von Altium nicht getestet werden. Es ist
defensiv geschrieben (Timeouts, Fehlerdialoge, Board-Prüfung). Beim ersten
Einsatz empfiehlt sich ein **kleines Test-Board**: einen Fix anwenden, im Board
kontrollieren, `Strg+Z` testen. Je nach Altium-Version kann eine API-Kleinigkeit
abweichen – dann bitte die Fehlermeldung im Python-Konsolenfenster bzw. den
Statustext im Skriptfenster ansehen.
