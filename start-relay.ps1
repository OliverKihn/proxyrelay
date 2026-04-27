# Startet das proxy-relay im Hintergrund (ohne Fenster) und uebergibt die
# DPAPI-verschluesselten Zugangsdaten ueber eine InMemory-stdin-Pipe.
# Es wird KEINE Datei mit Klartext-Credentials angelegt.
#
# Voraussetzung: .\setup-relay-credentials.ps1 wurde einmalig ausgefuehrt.
#
# Nach dem Start:
#   - PID liegt in   %APPDATA%\proxy-relay\relay.pid (PID des cmd-Wrappers)
#   - stdout in      %APPDATA%\proxy-relay\relay.log
#   - stderr in      %APPDATA%\proxy-relay\relay.err.log
# Stoppen (cmd-Wrapper inkl. node-Kindprozess):
#   taskkill /T /F /PID (Get-Content "$env:APPDATA\proxy-relay\relay.pid")

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$credDir    = Join-Path $env:APPDATA 'proxy-relay'
$userFile   = Join-Path $credDir 'user.txt'
$passFile   = Join-Path $credDir 'pass.dpapi'
$pidFile    = Join-Path $credDir 'relay.pid'
$logFile    = Join-Path $credDir 'relay.log'
$errLogFile = Join-Path $credDir 'relay.err.log'
$relayJs    = Join-Path $PSScriptRoot 'proxy-relay.js'

if (-not (Test-Path $userFile) -or -not (Test-Path $passFile)) {
    Write-Error "Keine Credentials gefunden. Erst .\setup-relay-credentials.ps1 ausfuehren."
}
if (-not (Test-Path $relayJs)) {
    Write-Error "proxy-relay.js nicht gefunden: $relayJs"
}

# Falls bereits ein Relay laeuft: Hinweis und Abbruch.
if (Test-Path $pidFile) {
    $oldPidText = (Get-Content $pidFile -Raw).Trim()
    if ($oldPidText -match '^\d+$') {
        $existing = Get-Process -Id ([int]$oldPidText) -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "proxy-relay laeuft bereits (PID $oldPidText)."
            Write-Host "Stoppen mit:  taskkill /T /F /PID $oldPidText"
            return
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}

$user = (Get-Content $userFile -Raw).Trim()

# DPAPI-Entschluesselung: gelingt nur als der User, der setup-relay-credentials.ps1 ausgefuehrt hat
try {
    $secure = Get-Content $passFile -Raw | ConvertTo-SecureString
} catch {
    Write-Error "Entschluesselung fehlgeschlagen. DPAPI-Blob ist an $env:USERNAME @ $env:COMPUTERNAME gebunden. Original: $($_.Exception.Message)"
}

$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$plain = $null
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    # Wir starten cmd.exe als Wrapper. cmd uebernimmt die stdout/stderr-
    # Umleitung in Logdateien (>> = anhaengen). Stdin wird ueber eine
    # anonyme Pipe direkt von PowerShell beschrieben - kein Klartext auf
    # der Festplatte. Nach dem Schreiben der zwei Zeilen schliessen wir
    # die Pipe; der Node-Kindprozess uebernimmt die Handles und laeuft
    # weiter, auch nachdem dieses Skript endet.
    $cmdArgs = '/d /c node "{0}" 1>>"{1}" 2>>"{2}"' -f $relayJs, $logFile, $errLogFile

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $env:ComSpec
    $psi.Arguments              = $cmdArgs
    $psi.WorkingDirectory       = $PSScriptRoot
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Credentials direkt als UTF-8-Bytes in die stdin-Pipe schreiben.
    # (PS 5.1/.NET Framework kennt kein ProcessStartInfo.StandardInputEncoding,
    # daher BaseStream statt StreamWriter verwenden.)
    $utf8  = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes("$user`n$plain`n")
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()

    # PID des cmd-Wrappers merken (taskkill /T raeumt den node-Kindprozess mit ab).
    Set-Content -Path $pidFile -Value $proc.Id -Encoding ASCII -NoNewline

    Write-Host "proxy-relay laeuft im Hintergrund als $user (Wrapper-PID $($proc.Id))."
    Write-Host "Log:    $logFile"
    Write-Host "Errlog: $errLogFile"
    Write-Host "Stop:   taskkill /T /F /PID $($proc.Id)"
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if ($plain)  { Remove-Variable plain -ErrorAction SilentlyContinue }
    if ($secure) { $secure.Dispose() }
}
