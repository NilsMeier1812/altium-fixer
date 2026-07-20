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

**Was exportiert wird:** alle Innenlagen, aber **nur Tracks mit Net** und **ohne
TOP/BOTTOM**. TOP und BOTTOM sollen nie ausgewertet werden und werden schon beim
Export übersprungen (spart die meiste Arbeit). Tracks ohne Net sind vor allem die
Füllprimitive von Kupferflächen/Polygonen – sie tragen kein Net, machen aber oft
den Großteil der Objekte aus (z. B. 300k+). Die Analyse braucht das Net ohnehin
(gruppiert nach Layer + Net), also fliegen sie raus. Das reduziert die Datenmenge
drastisch und stellt sicher, dass jeder exportierte Track ein Net hat. Zum Prüfen
der Net-Situation gibt es `DiagTests.VC_T8_NetCheck`.

**Layer im Report filtern:** Oben im Report gibt es eine **Layer-Filterleiste**
(Checkbox je Layer mit Fehleranzahl, plus „alle"/„keine") – damit blendet man
Layer live ein/aus, ohne neu zu exportieren. Der „offen"-Zähler zählt nur die
eingeblendeten Layer. (Weitere Layer schon beim Export weglassen: in
`RunVerbindungsCheck` in der Track-Schleife die `eTopLayer`/`eBottomLayer`-Bedingung
um weitere Layer ergänzen.)

> **Große Boards:** Altium-Skripte iterieren einzeln über jedes Objekt – das ist
> langsam und kann bei sehr großen Boards **mehrere Minuten** dauern. Während
> `RunVerbindungsCheck` läuft, zeigt ein **Fortschrittsfenster** einen mitlaufenden
> Zähler (geprüfte Objekte / exportierte Tracks / übersprungene TOP-BOTTOM), damit
> man sieht, dass es noch arbeitet. Bitte **nicht abbrechen**. Eine Not-Bremse
> (`MAX_ITER`) verhindert ein Endlos-Hängen. TOP/BOTTOM werden gar nicht erst
> exportiert – das spart bei mehrlagigen Boards den Großteil der Arbeit.

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
Den kompletten Ordner nach **`C:\altium-track-fixer`** legen (dieser Pfad ist
im Skript und in den `.bat`-Dateien **fest verdrahtet**). Struktur:

```
C:\altium-track-fixer\
  check_server.py
  check_excel.py
  start_watcher_hidden.vbs  <- Watcher UNSICHTBAR starten (empfohlen, in den Autostart)
  start_watcher.bat         <- Watcher mit sichtbarem Fenster (zum Debuggen)
  start_server.bat          <- Einmal-Server (Alternative, pro Durchlauf 1 Klick)
  verbindungs_check\        <- Analyse-Kern (nicht umbenennen)
  altium\VerbindungsCheck.pas   <- Skript-Code (Export + Holen-Fenster)
  altium\VerbindungsCheck.dfm   <- Formular (gehört zwingend dazu, gleicher Name!)
  altium\VerbindungsCheck.PrjScr
```

> **`.pas` und `.dfm` gehören zusammen.** Sie müssen im selben Ordner liegen und
> gleich heißen. Das Formular liefert das Fenster mit dem Button „Änderungen aus
> dem Browser holen". Ein **Timer** ist bewusst **nicht** drin (der brauchte es
> nicht): ein Klick holt genau einmal. Wichtig: Formulare in Altium werden aus
> der `.dfm` **automatisch** erzeugt – im Code **kein** `TVCForm.Create`, nur
> `VCForm.ShowModal`.

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
2. **`start_watcher_hidden.vbs`** (oder eine Verknüpfung darauf) dort hineinlegen.
3. Fertig. Ab dem nächsten Login läuft der Watcher automatisch – **komplett
   unsichtbar**, kein schwarzes Konsolenfenster.

> **Kein Fenster:** `start_watcher_hidden.vbs` startet den Server über
> `pythonw.exe` (Python ohne Konsole) und mit verstecktem Fenster. Ist `pythonw`
> nicht im PATH, oben in der `.vbs` den vollen Pfad eintragen
> (`PY = "C:\Python312\pythonw.exe"`). **Beenden** (läuft ja unsichtbar):
> Task-Manager → Prozess `pythonw.exe`.
>
> Zum **Debuggen** stattdessen `start_watcher.bat` doppelklicken – die zeigt das
> Konsolenfenster mit Log-Ausgaben. `start_server.bat` bleibt die Einmal-Variante.

### 3. Altium-Skript einbinden
1. In Altium: **File → Open** → `altium\VerbindungsCheck.PrjScr` (Skriptprojekt).
2. Alternativ **DXP → Run Script… → Browse** → `altium\VerbindungsCheck.pas`.
3. Die Prozedur **`RunVerbindungsCheck`** wählen → **OK**.

> `RunVerbindungsCheck` exportiert **und** öffnet danach das Fenster mit dem
> Button „Änderungen aus dem Browser holen". `ApplyFixes` ist nur der Fallback,
> falls das Fenster schon geschlossen ist.

Der Arbeitsordner ist **fest auf `C:\altium-track-fixer`** verdrahtet (Funktion
`VCWorkDir` oben in `VerbindungsCheck.pas`) – das Skript fragt nichts mehr ab.
Liegt das Repo woanders, den Pfad in `VCWorkDir` anpassen. Dorthin schreibt das Skript
`tracks.json` und die Bridge-Dateien.

> Python-Pfad steht in `start_watcher.bat` / `start_server.bat`. Falls `python`
> nicht im PATH ist, dort oben `set PY=C:\Pfad\zu\python.exe` eintragen.

---

## Benutzung (Altium)

1. Das gewünschte **`.PcbDoc` öffnen** und das **PCB-Fenster in den Vordergrund**
   holen (aktives Dokument – sonst ist der PCB-Server nicht bereit).
2. **`RunVerbindungsCheck`** ausführen (kein Ordner-Dialog – Pfad ist fest).
   - Liest die Tracks (**ohne TOP/BOTTOM, nur mit Net**) und schreibt
     `tracks.json`. Ein **Fortschrittsfenster** mit mitlaufendem Zähler zeigt,
     dass es arbeitet; bei großen Boards dauert der Export einige Minuten.
   - Der Hintergrund-Watcher merkt das in ~1 s und **öffnet den Browser
     automatisch**. (Ohne Watcher: einmal `start_server.bat` doppelklicken.)
   - Danach geht in Altium ein **Fenster** auf. Altium ist ab jetzt blockiert –
     das macht nichts, du arbeitest jetzt im Browser.
3. Im Report jeden Fehler prüfen. Passt der grün markierte Zielpunkt, auf
   **„In Altium fixen"** klicken – beliebig viele. Die Blöcke zeigen
   **„wartet – in Altium 'Änderungen holen' klicken"**.
4. Zurück in Altium: im Fenster auf **„Änderungen übernehmen"**.
   - Das Fenster geht **kurz zu**, alle angeklickten Fixes werden **in einem
     Rutsch** ins Board übernommen (das Board zeichnet dabei sichtbar neu), und
     das Fenster **öffnet sich automatisch wieder**. Im Browser wechseln die
     Fixes auf **„Behoben in Altium"**. **`Strg+Z`** macht die Runde rückgängig.
   - Das ist eine **Dauerschleife:** im Browser weitere Fehler anklicken →
     wieder „Änderungen übernehmen" → usw. – **ohne** erneuten (langen) Export.
5. **„Fertig"** beendet die Schleife und schließt das Fenster. Für weitere Fixes
   danach: `ApplyFixes` (baut die Zuordnung neu auf – dauert wieder etwas) oder
   `RunVerbindungsCheck` neu.

Browser ↔ Python läuft lokal über HTTP (`127.0.0.1`), Altium ↔ Python über
Dateien im Arbeitsordner (`bridge_cmd.txt` / `bridge_ack.txt`) – keine
Firewall-Freigabe nötig.

> **Warum kein Timer / kein Auto-Poll?** Braucht es nicht. Ein Klick auf
> „holen" zieht genau einmal alle offenen Fixes. Die Track-Liste liegt aus dem
> Export im Speicher, daher ist das Holen sofort da – ohne erneute Iteration
> über das große Board.

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
start_watcher_hidden.vbs    Watcher unsichtbar starten (pythonw, kein Fenster) – für den Autostart
start_watcher.bat           Watcher mit sichtbarem Konsolenfenster (Debug)
start_server.bat            Einmal-Server (Alternative; Altium kann keinen Prozess starten)
altium/VerbindungsCheck.pas DelphiScript: RunVerbindungsCheck (Export + Holen-Fenster) + ApplyFixes
altium/VerbindungsCheck.dfm Formular (Status + "Aenderungen uebernehmen" + "Fertig")
tests/test_fixes.py         Geometrie- und Analyse-Tests
```

### Protokoll

```
Browser  --POST /fix {fix_id}-->  Server            (HTTP, legt Fix in Queue)
Browser  --GET  /status-------->  Server            (HTTP, Anzeige: wartet/behoben/veraltet)

Server   --schreibt---> bridge_cmd.txt  --liest-->  Altium   (offene Fixes, beim "holen")
Altium   --schreibt---> bridge_ack.txt  --liest-->  Server   (erledigt: fix_id;1)
```

Grund für die Datei-Bridge: Das Altium-DelphiScript kennt hier kein
`CreateOleObject` (kein HTTP/OLE aus Altium). Datei-I/O geht dagegen zuverlässig.

Track-Identität: `RunVerbindungsCheck` vergibt die ID als **Iterations-Index**
über die Tracks mit Net und hält die Referenzen im Fenster **im Speicher** –
das „Holen" nutzt sie direkt (keine erneute Iteration). Der Fallback `ApplyFixes`
(nach dem Schließen) iteriert das Board in **derselben Reihenfolge** erneut und
rekonstruiert die Zuordnung. Wichtig: das **gleiche PcbDoc** muss aktiv sein und
sollte zwischen Export und Anwenden nicht strukturell verändert werden (Tracks
hinzufügen/löschen verschiebt die IDs).

---

## Hinweis zum Altium-Skript

`VerbindungsCheck.pas` kann außerhalb von Altium nicht getestet werden. Es ist
defensiv geschrieben (Fehlerdialoge, `PCBServer`-Prüfung, Board-Prüfung). Das
Formular hat **keinen Timer** (ein Klick auf „holen" reicht), und die Form wird
aus der `.dfm` **automatisch** erzeugt (im Code kein `TVCForm.Create`). Beim
ersten Einsatz empfiehlt sich ein **kleines Test-Board**: `RunVerbindungsCheck`,
im Browser einen Fehler anklicken, „Änderungen aus dem Browser holen", im Board
kontrollieren, `Strg+Z` testen. Je nach Altium-Version kann eine API-Kleinigkeit
abweichen – dann bitte die genaue Fehlermeldung notieren.
