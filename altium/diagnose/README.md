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
