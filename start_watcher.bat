@echo off
REM ============================================================
REM  Verbindungs-Check - HINTERGRUND-WATCHER (empfohlen)
REM
REM  Startet den Python-Server EINMAL und laesst ihn dauerhaft
REM  laufen. Er wartet auf tracks.json in C:\altium-track-fixer.
REM  Sobald Altium (RunVerbindungsCheck) sie schreibt, baut er den
REM  Report und oeffnet den Browser AUTOMATISCH.
REM
REM  -> Damit muss man im Alltag NUR in Altium klicken.
REM
REM  Am besten EINMALIG in den Windows-Autostart legen:
REM    1. Win+R druecken, "shell:startup" eingeben, Enter.
REM    2. Rechtsklick in den Ordner -> Neu -> Verknuepfung.
REM    3. Als Ziel diese Datei (start_watcher.bat) waehlen.
REM
REM  Falls "python" nicht gefunden wird: unten den vollen Pfad zur
REM  python.exe eintragen, z.B.  set PY=C:\Python312\python.exe
REM ============================================================

set PY=python
set DIR=C:\altium-track-fixer

cd /d "%DIR%"

"%PY%" "%DIR%\check_server.py" --watch "%DIR%"

echo.
echo Watcher beendet. Fenster kann geschlossen werden.
pause
