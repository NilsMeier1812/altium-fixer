' ============================================================
'  Verbindungs-Check - Watcher UNSICHTBAR starten (kein Fenster)
'
'  Startet den Python-Watcher komplett ohne Konsolenfenster.
'  Diese .vbs in den Windows-Autostart legen (statt start_watcher.bat):
'    1. Win+R -> shell:startup -> Enter
'    2. Diese Datei (oder eine Verknuepfung darauf) dort hineinlegen.
'
'  Nutzt pythonw.exe = Python OHNE Konsole. Ist "pythonw" nicht im PATH,
'  unten den vollen Pfad eintragen, z.B.:
'    PY = "C:\Python312\pythonw.exe"
'
'  Beenden (laeuft ja unsichtbar): Task-Manager -> Prozess "pythonw.exe".
' ============================================================

Dim DIR, PY, cmd
DIR = "C:\altium-track-fixer"
PY  = "pythonw"

cmd = """" & PY & """ """ & DIR & "\check_server.py"" --watch """ & DIR & """"

' 0 = verstecktes Fenster, False = nicht auf Ende warten
CreateObject("WScript.Shell").Run cmd, 0, False
