@echo off
REM ============================================================
REM  Verbindungs-Check - Server starten (Altium-Live, Datei-Bridge)
REM
REM  Voraussetzung: Das Altium-Skript (RunVerbindungsCheck) hat
REM  tracks.json in DIESEM Ordner erzeugt.
REM
REM  Doppelklick startet den Python-Server. Er liest tracks.json,
REM  oeffnet den Browser-Report und legt die Bridge-Dateien
REM  (bridge_cmd.txt / bridge_ack.txt) hier ab.
REM
REM  Falls "python" nicht gefunden wird: unten den vollen Pfad zur
REM  python.exe eintragen, z.B.  set PY=C:\Python312\python.exe
REM ============================================================

cd /d "%~dp0"

set PY=python

if not exist "%~dp0tracks.json" (
  echo.
  echo tracks.json fehlt in diesem Ordner.
  echo Bitte zuerst in Altium das Skript "RunVerbindungsCheck" ausfuehren.
  echo.
  pause
  exit /b 1
)

"%PY%" "%~dp0check_server.py" "%~dp0tracks.json"

echo.
echo Server beendet. Fenster kann geschlossen werden.
pause
