@echo off
REM ============================================================
REM  Verbindungs-Check - Server EINMAL starten (Alternative)
REM
REM  Voraussetzung: Das Altium-Skript (RunVerbindungsCheck) hat
REM  tracks.json in C:\altium-track-fixer erzeugt.
REM
REM  Fuer den Alltag besser: start_watcher.bat (laeuft dauerhaft
REM  und oeffnet den Report automatisch).
REM
REM  Falls "python" nicht gefunden wird: unten den vollen Pfad zur
REM  python.exe eintragen, z.B.  set PY=C:\Python312\python.exe
REM ============================================================

set PY=python
set DIR=C:\altium-track-fixer

cd /d "%DIR%"

if not exist "%DIR%\tracks.json" (
  echo.
  echo tracks.json fehlt in %DIR%.
  echo Bitte zuerst in Altium das Skript "RunVerbindungsCheck" ausfuehren.
  echo.
  pause
  exit /b 1
)

"%PY%" "%DIR%\check_server.py" "%DIR%\tracks.json"

echo.
echo Server beendet. Fenster kann geschlossen werden.
pause
