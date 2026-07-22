# Diagnose-Skripte (nur bei Problemen nötig)

Diese Skripte werden für die **normale Benutzung nicht gebraucht**. Sie sind
nur da, um bei Problemen (z. B. Skript hängt, keine Nets, seltsame Zahlen) den
Fehler einzugrenzen.

## DiagTests.pas

Enthält kleine, unabhängige Testprozeduren:

| Prozedur              | Zweck |
|-----------------------|-------|
| `VC_T1_Hello`         | Läuft DelphiScript überhaupt? (nur ShowMessage) |
| `VC_T2_Board`         | Ist ein PCB-Board aktiv/erreichbar? |
| `VC_T3_Input`         | Kommt die Eingabe-/Dialog-Ebene durch? |
| `VC_T4_CountTracks`   | Wie viele Track-Objekte hat das Board? |
| `VC_T5_FirstTrackProps` | Eigenschaften des ersten Tracks anzeigen |
| `VC_T6_WriteFile`     | Kann in den Arbeitsordner geschrieben werden? |
| `VC_T7_ExportCapped`  | Export mit Deckel (nur erste N Tracks) |
| `VC_T8_NetCheck`      | Wie viele Tracks haben ein Net / keins? |

### Ausführen

Diese Datei ist **absichtlich nicht** im Haupt-Skriptprojekt
(`VerbindungsCheck.PrjScr`), damit im Altium-„Run Script"-Dialog nur die zwei
wirklich benötigten Skripte auftauchen. Zum Ausführen bei Bedarf:

1. In Altium **DXP → Run Script…** → **Browse** → diese `DiagTests.pas` wählen.
2. Die gewünschte `VC_T*`-Prozedur auswählen und starten.

## QueryFilterTest.pas (Experiment: Netless-Vorfilter)

Testet, ob sich Tracks **ohne Net** über die native Query-Engine **vorfiltern**
lassen (wie im PCB-Filter-Panel `(ObjectKind = 'Track') And Not (Net = 'No Net')`),
statt sie einzeln in der Schleife per `Trk.Net = nil` auszusortieren.

**Ausführen** (falls „Run Script → Browse" bei dir nur mit Projekt geht):
In Altium **File → Open** → `altium/diagnose/QueryFilterTest.PrjScr` (Skriptprojekt),
dann **DXP → Run Script…** → Prozedur **`TestQueryFilter`** wählen. Alternativ,
wenn eine lose `.pas` bei dir doch läuft: direkt `QueryFilterTest.pas` browsen.

Prozedur **`TestQueryFilter`** macht in einem Durchlauf:

- **Referenz** per Voll-Iteration: Tracks gesamt / mit Net / mit Net & ohne
  TOP-BOTTOM, mit Zeitmessung.
- **Query-Vorfilter** über `RunProcess('PCB:RunQuery')` (Tracks mit Net
  selektieren), mit Zeitmessung.
- **Kreuzcheck**: `SelectecObjectCount` direkt **und** nochmal über alle Tracks
  `Selected` zählen.

Am Ende eine `ShowMessage` mit allen Zahlen. Deutung:

- Kommt beim Start **„Undeclared identifier: RunProcess"** (o. ä.): der
  Query-Aufruf existiert in dieser DelphiScript-Umgebung nicht → es bleibt beim
  Prüfen pro Primitive.
- Läuft es, aber **Selected = 0**: Prozess/Parameter greifen anders → die
  gemeldeten Zahlen schicken, dann passe ich die Parameter an.
- **Selected == „mit Net"**: funktioniert → der Umbau lohnt sich.

> **Achtung:** Das Skript **verändert deine aktuelle Auswahl** (selektiert per
> Query und deselektiert am Ende alles). Sonst wird nichts am Board geändert.
> Dieses Skript ist ein **Experiment** und liegt bewusst nur auf dem
> Entwicklungs-Branch, nicht auf `main`.
