@echo off
REM ============================================================
REM  Verbindungs-Check - Ein-Klick-Einrichtung (Starter)
REM
REM  Doppelklick genuegt. Diese .bat besorgt sich Administrator-
REM  Rechte und startet setup.ps1 (die eigentliche Einrichtung).
REM
REM  Liegt setup.ps1 neben dieser Datei (z.B. im geklonten Repo),
REM  wird sie direkt genutzt. Sonst wird sie einmalig von GitHub
REM  geladen - so reicht fuer einen neuen Rechner ALLEIN diese
REM  setup.bat als Download.
REM ============================================================

setlocal
set "PS1_LOCAL=%~dp0setup.ps1"
set "PS1_RAW=https://raw.githubusercontent.com/NilsMeier1812/altium-track-fixer/main/setup.ps1"

if exist "%PS1_LOCAL%" (
  echo Starte lokale Einrichtung: "%PS1_LOCAL%"
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS1_LOCAL%\"'"
) else (
  echo setup.ps1 nicht lokal gefunden - lade sie von GitHub ...
  set "PS1_TMP=%TEMP%\altium-track-fixer-setup.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Invoke-WebRequest -Uri '%PS1_RAW%' -OutFile '%TEMP%\altium-track-fixer-setup.ps1' -UseBasicParsing } catch { Write-Host 'Download fehlgeschlagen:' $_.Exception.Message -ForegroundColor Red; exit 1 }"
  if errorlevel 1 (
    echo.
    echo Konnte setup.ps1 nicht herunterladen. Internetverbindung pruefen.
    pause
    exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%TEMP%\altium-track-fixer-setup.ps1\"'"
)

endlocal
