<#
================================================================
 Verbindungs-Check - Automatische Einrichtung (Windows)
================================================================

 Richtet ALLES ein, was fuer den Altium-Live-Modus noetig ist:

   1. Python pruefen  -> sonst installieren (winget, sonst Direkt-Download)
   2. Git pruefen     -> sonst installieren (winget) [optional, fuer Updates]
   3. Repo nach C:\altium-track-fixer holen (git clone / ZIP-Download)
   4. pip install -r requirements.txt (nur fuer den Excel-Modus noetig)
   5. start_watcher_hidden.vbs in den Windows-Autostart legen
   6. Den Watcher EINMAL sofort starten (unsichtbar)

 Was NICHT automatisch geht (muss einmal von Hand in Altium passieren):
   - Das Skriptprojekt in Altium oeffnen (File -> Open ->
     altium\VerbindungsCheck.PrjScr). Das laeuft in der Altium-GUI und
     kann von aussen nicht gescriptet werden. Das Skript zeigt diesen
     letzten Schritt am Ende noch einmal an.

 Aufruf:
   - Bequem: setup.bat doppelklicken (holt Admin-Rechte + dieses Skript).
   - Direkt: Rechtsklick auf setup.ps1 -> "Mit PowerShell ausfuehren".
   Das Skript fordert bei Bedarf selbst Administrator-Rechte an.
================================================================
#>

param(
    [string]$InstallDir = "C:\altium-track-fixer",
    [string]$RepoUrl    = "https://github.com/NilsMeier1812/altium-track-fixer.git",
    [string]$Branch     = "main"
)

$ErrorActionPreference = "Stop"
$ZipUrl = "https://codeload.github.com/NilsMeier1812/altium-track-fixer/zip/refs/heads/$Branch"

# ---------- kleine Ausgabe-Helfer -------------------------------------------
function Info($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [ok]  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!]   $m" -ForegroundColor Yellow }
function Step($m) { Write-Host "    ...   $m" -ForegroundColor Gray }

function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# PATH neu aus der Registry laden (nach einer Installation weiss die aktuelle
# Sitzung sonst nichts von neu hinzugekommenen Programmen wie python/git).
function Update-EnvPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
}

# ---------- Administrator-Rechte sicherstellen ------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if (-not $isAdmin) {
    if ($PSCommandPath) {
        Info "Fordere Administrator-Rechte an (fuer Installationen + C:\-Ordner) ..."
        $argList = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-InstallDir", "`"$InstallDir`"",
            "-RepoUrl", "`"$RepoUrl`"",
            "-Branch", "`"$Branch`""
        )
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs
        exit
    } else {
        Warn "Ohne Administrator-Rechte gestartet. Bitte PowerShell 'als Administrator'"
        Warn "oeffnen und das Skript erneut ausfuehren (oder setup.bat doppelklicken)."
        Read-Host "Zum Beenden Enter druecken"
        exit 1
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host " Verbindungs-Check - Automatische Einrichtung" -ForegroundColor White
Write-Host " Zielordner: $InstallDir" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

$hasWinget = Have "winget"
if (-not $hasWinget) {
    Warn "winget ist nicht vorhanden. Installationen laufen ueber Direkt-Download."
    Warn "(winget kommt mit dem 'App Installer' aus dem Microsoft Store, empfohlen auf Win10/11.)"
}

# ============================================================================
# 1. Python
# ============================================================================
function Install-PythonViaWinget {
    Step "Installiere Python 3.12 ueber winget ..."
    winget install --id Python.Python.3.12 --scope machine --silent `
        --accept-source-agreements --accept-package-agreements | Out-Host
}

function Install-PythonViaDownload {
    $url = "https://www.python.org/ftp/python/3.12.6/python-3.12.6-amd64.exe"
    $exe = Join-Path $env:TEMP "python-3.12.6-amd64.exe"
    Step "Lade Python-Installer herunter ..."
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    Step "Installiere Python (still, fuer alle Benutzer, PATH wird gesetzt) ..."
    # PrependPath=1 -> python/pythonw landen im PATH; Include_launcher=1 -> "py"
    Start-Process -FilePath $exe -ArgumentList `
        "/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1" -Wait
    Remove-Item $exe -ErrorAction SilentlyContinue
}

function Ensure-Python {
    Info "Pruefe Python ..."
    Update-EnvPath
    if (Have "python") {
        $v = (& python --version) 2>&1
        Ok "Python gefunden: $v"
        return
    }
    Warn "Python nicht gefunden - wird installiert."
    if ($hasWinget) { Install-PythonViaWinget } else { Install-PythonViaDownload }
    Update-EnvPath
    if (Have "python") {
        $v = (& python --version) 2>&1
        Ok "Python installiert: $v"
    } else {
        throw "Python-Installation fehlgeschlagen oder noch nicht im PATH. " +
              "Bitte einmal ab-/anmelden und das Setup erneut starten."
    }
}

# ============================================================================
# 2. Git (optional - fuer bequeme spaetere Updates per 'git pull')
# ============================================================================
function Ensure-Git {
    Info "Pruefe Git ..."
    Update-EnvPath
    if (Have "git") {
        Ok "Git gefunden: $((& git --version) 2>&1)"
        return
    }
    if ($hasWinget) {
        Warn "Git nicht gefunden - wird installiert (fuer spaetere Updates)."
        Step "Installiere Git ueber winget ..."
        try {
            winget install --id Git.Git --scope machine --silent `
                --accept-source-agreements --accept-package-agreements | Out-Host
            Update-EnvPath
        } catch {
            Warn "Git-Installation fehlgeschlagen - nicht schlimm, es geht auch per ZIP."
        }
    } else {
        Warn "Kein winget vorhanden - Git wird uebersprungen (Repo kommt per ZIP)."
    }
    if (Have "git") { Ok "Git installiert: $((& git --version) 2>&1)" }
}

# ============================================================================
# 3. Repo nach $InstallDir holen
# ============================================================================
function Get-RepoViaZip {
    $zip = Join-Path $env:TEMP "altium-track-fixer.zip"
    $tmp = Join-Path $env:TEMP "altium-track-fixer-extract"
    Step "Lade Repo als ZIP herunter ..."
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Step "Entpacke ..."
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    # Das ZIP enthaelt einen Unterordner "altium-track-fixer-<branch>".
    $inner = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $inner.FullName "*") -Destination $InstallDir -Recurse -Force
    Remove-Item $zip -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

function Ensure-Repo {
    Info "Hole das Repo nach $InstallDir ..."

    if (Test-Path (Join-Path $InstallDir ".git")) {
        Step "Repo existiert bereits - aktualisiere (git pull) ..."
        try {
            & git -C $InstallDir pull --ff-only | Out-Host
            Ok "Repo aktualisiert."
        } catch {
            Warn "git pull fehlgeschlagen (lokale Aenderungen?). Bestand bleibt unveraendert."
        }
        return
    }

    # Ordner existiert, ist aber kein Git-Repo -> vorhandenen Bestand sichern.
    if ((Test-Path $InstallDir) -and (Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue)) {
        $backup = "$InstallDir" + "_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss")
        Warn "Ordner existiert und ist kein Git-Repo. Sichere ihn nach:"
        Warn "  $backup"
        Rename-Item -Path $InstallDir -NewName $backup
    }

    if (Have "git") {
        Step "Klone Repo (git clone) ..."
        & git clone --branch $Branch $RepoUrl $InstallDir | Out-Host
        Ok "Repo geklont."
    } else {
        Get-RepoViaZip
        Ok "Repo per ZIP abgelegt (ohne Git - Updates dann von Hand)."
    }
}

# ============================================================================
# 4. Python-Pakete (nur Excel-Modus)
# ============================================================================
function Ensure-Requirements {
    Info "Installiere Python-Pakete fuer den Excel-Modus (optional) ..."
    $req = Join-Path $InstallDir "requirements.txt"
    if (-not (Test-Path $req)) { Warn "requirements.txt nicht gefunden - uebersprungen."; return }
    try {
        & python -m pip install --upgrade pip | Out-Host
        & python -m pip install -r $req | Out-Host
        Ok "Excel-Pakete installiert (pandas, openpyxl)."
    } catch {
        Warn "pip-Installation fehlgeschlagen. Der Altium-Live-Modus laeuft trotzdem"
        Warn "(er braucht keine Zusatzpakete). Nur der Excel-Fallback faellt dann aus."
    }
}

# ============================================================================
# 5. Autostart einrichten
# ============================================================================
function Ensure-Autostart {
    Info "Lege eine Verknuepfung des Watchers in den Autostart ..."
    $vbs = Join-Path $InstallDir "start_watcher_hidden.vbs"
    if (-not (Test-Path $vbs)) { Warn "start_watcher_hidden.vbs fehlt - uebersprungen."; return }
    $startup = [Environment]::GetFolderPath("Startup")

    # Alte KOPIE aus frueheren Setup-Versionen entfernen (sonst startet der
    # Watcher doppelt: einmal ueber die Kopie, einmal ueber die Verknuepfung).
    $oldCopy = Join-Path $startup "Verbindungs-Check-Watcher.vbs"
    if (Test-Path $oldCopy) {
        Remove-Item $oldCopy -Force -ErrorAction SilentlyContinue
        Step "Alte Autostart-Kopie entfernt: $oldCopy"
    }

    # VERKNUEPFUNG statt Kopie: sie zeigt auf die .vbs im Repo. So laeuft nach
    # einem 'git pull' automatisch die aktuelle Version - kein erneutes Setup.
    $link = Join-Path $startup "Verbindungs-Check-Watcher.lnk"
    $wsh  = New-Object -ComObject WScript.Shell
    $sc   = $wsh.CreateShortcut($link)
    $sc.TargetPath       = $vbs
    $sc.WorkingDirectory = $InstallDir
    $sc.Description       = "Verbindungs-Check Hintergrund-Watcher"
    $sc.Save()

    Ok "Verknuepfung im Autostart angelegt:"
    Step "$link  ->  $vbs"
    Step "(Der Watcher startet ab dem naechsten Windows-Login automatisch, unsichtbar.)"
    Step "Nach einem Update genuegt 'git pull' - die Verknuepfung bleibt gueltig."
}

# ============================================================================
# 6. Watcher einmal jetzt starten
# ============================================================================
function Start-WatcherNow {
    Info "Starte den Watcher jetzt einmal (unsichtbar) ..."
    $vbs = Join-Path $InstallDir "start_watcher_hidden.vbs"
    if (-not (Test-Path $vbs)) { Warn "start_watcher_hidden.vbs fehlt - nicht gestartet."; return }
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbs`""
    Ok "Watcher laeuft im Hintergrund (Prozess 'pythonw.exe' im Task-Manager)."
}

# ============================================================================
# Ablauf
# ============================================================================
try {
    Ensure-Python
    Ensure-Git
    Ensure-Repo
    Ensure-Requirements
    Ensure-Autostart
    Start-WatcherNow

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " FERTIG - fast alles ist eingerichtet." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host " Noch EIN Schritt von Hand (nur einmalig, laeuft in Altium):" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   1. Altium oeffnen." -ForegroundColor White
    Write-Host "   2. File -> Open ->" -ForegroundColor White
    Write-Host "      $InstallDir\altium\VerbindungsCheck.PrjScr" -ForegroundColor White
    Write-Host "   3. Dann das gewuenschte .PcbDoc oeffnen, PCB-Fenster nach vorne," -ForegroundColor White
    Write-Host "      und das Skript 'RunVerbindungsCheck' ausfuehren." -ForegroundColor White
    Write-Host ""
    Write-Host " Ab dann: nur noch in Altium klicken - der Report oeffnet sich" -ForegroundColor White
    Write-Host " automatisch. Details stehen in der README.md." -ForegroundColor White
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " FEHLER bei der Einrichtung:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
}
finally {
    Read-Host "Zum Schliessen dieses Fensters Enter druecken"
}
