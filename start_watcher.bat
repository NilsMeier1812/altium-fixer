@echo off
REM ============================================================
REM  Verbindungs-Check - HINTERGRUND-WATCHER (empfohlen)
REM
REM  Startet den Python-Server EINMAL und laesst ihn dauerhaft
REM  laufen. Er wartet auf tracks.json in diesem Ordner. Sobald
REM  Altium (RunVerbindungsCheck) sie schreibt, baut er den Report
REM  und oeffnet den Browser AUTOMATISCH.
REM
REM  -> Damit muss man im Alltag NUR in Altium klicken.
REM
REM  Am besten EINMALIG in den Windows-Autostart legen:
REM    1. Win+R druecken, "shell:startup" eingeben, Enter.
REM    2. Rechtsklick in den Ordner -> Neu -> Verknuepfung.
REM    3. Als Ziel diese Datei (start_watcher.bat) waehlen.
REM  Danach startet der Watcher bei jeder Windows-Anmeldung selbst.
REM
REM  Falls "python" nicht gefunden wird: unten den vollen Pfad zur
REM  python.exe eintragen, z.B.  set PY=C:\Python312\python.exe
REM ============================================================

cd /d "%~dp0"

set PY=python

"%PY%" "%~dp0check_server.py" --watch "%~dp0"

echo.
echo Watcher beendet. Fenster kann geschlossen werden.
pause
