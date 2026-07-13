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
  verbindungs_check\        <- Analyse-Kern (nicht umbenennen)
  altium\VerbindungsCheck.pas   <- Skript-Code
  altium\VerbindungsCheck.dfm   <- Formular (gehört zwingend dazu!)
  altium\VerbindungsCheck.PrjScr
```

> **Wichtig:** `.pas` und `.dfm` müssen zusammen im selben Ordner liegen und
> gleich heißen. Das Formular (mit Timer) ist der Grund, warum die Live-
> Übernahme läuft, ohne Altium einzufrieren.

### 3. Altium-Skript einbinden
1. In Altium: **File → Open** → `altium\VerbindungsCheck.PrjScr` (das Skript-
   projekt öffnen – so werden `.pas` und `.dfm` als Paar geladen).
2. Alternativ **DXP → Run Script… → Browse** → `altium\VerbindungsCheck.pas`
   (die `.dfm` daneben wird automatisch mitgeladen).
3. Die Prozedur **`RunVerbindungsCheck`** wählen → **OK**.

Beim Start fragt das Skript in drei kleinen Dialogen ab:
- **Python-Programm:** `python` (oder der volle Pfad zur `python.exe`).
- **Skript-Ordner:** der Ordner mit `check_server.py`, z. B. `C:\Tools\altium-fixer`
  (dort wird auch `tracks.json` abgelegt).
- **Port:** `8765` (Standard reicht; wird bei Belegung automatisch hochgezählt).

---

## Benutzung (Altium-Live)

1. Das gewünschte **`.PcbDoc` öffnen und aktiv** haben.
2. Skript starten (`RunVerbindungsCheck`) und die drei Dialoge bestätigen.
   - Das Skript liest alle Tracks, schreibt `tracks.json`, startet Python.
   - Ein **schwarzes Konsolenfenster** (Python) geht auf, der **Browser** öffnet
     den Report, und in Altium erscheint ein **kleines Status-Fenster** („läuft").
3. Im Report jeden Fehler prüfen. Passt der grün markierte Zielpunkt, auf
   **„In Altium fixen"** klicken.
   - Der Endpunkt wandert **sofort** im Board an die richtige Stelle.
   - Der Block wechselt auf **„Behoben in Altium"**.
   - Jeder Fix ist ein eigener **Undo-Schritt** in Altium (`Strg+Z`).
4. Betrifft ein späterer Fix einen schon geänderten Track, wird der Block als
   **veraltet** markiert – dann einfach den Check neu starten für den
   aktuellen Stand.
5. **Zum Beenden:** im Altium-Status-Fenster **„Stoppen/Schließen"** klicken,
   oder das schwarze **Python-Fenster schließen** (das Status-Fenster merkt das
   und meldet „beendet"). Danach das Python-Fenster schließen.

Während des Live-Fixens ist das kleine Status-Fenster in Altium offen; ein Timer
darin holt die Klicks ab und aktualisiert das Board bei jedem Fix. Altium bleibt
dabei bedienbar (der Timer blockiert nicht). Es läuft alles lokal (`127.0.0.1`),
keine Firewall-Freigabe nötig.

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
check_server.py             Altium-Live-Server (stdlib): HTTP + Fix-Queue
check_excel.py              Excel-Fallback (pandas/openpyxl + tkinter)
altium/VerbindungsCheck.pas DelphiScript: Export, Server-Start, Live-Fix-Polling
tests/test_fixes.py         Geometrie- und Analyse-Tests
```

### Protokoll (HTML ↔ Server ↔ Altium)

```
Browser  --POST /fix {fix_id}-->  Server (legt Fix in Queue)
Altium   --GET  /pending------->  Server (liefert "fix_id;track_id;end;x;y")
Altium   --GET  /ack?fix_id&ok->  Server (markiert erledigt)
Browser  --GET  /status-------->  Server (Anzeige: gesendet/behoben/veraltet)
```

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
