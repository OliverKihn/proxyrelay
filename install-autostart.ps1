# Registriert einen Logon-Task im Windows Task Scheduler, der
# start-relay.ps1 beim Anmelden des aktuellen Benutzers automatisch
# (versteckt, ohne Konsolenfenster) ausfuehrt.
#
# Deinstallieren:  .\install-autostart.ps1 -Uninstall

[CmdletBinding()]
param(
    [string]$TaskName = 'ProxyRelay-Autostart',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Aufgabe '$TaskName' entfernt."
    } else {
        Write-Host "Aufgabe '$TaskName' war nicht registriert."
    }
    return
}

$relayScript = Join-Path $PSScriptRoot 'start-relay.ps1'
if (-not (Test-Path $relayScript)) {
    Write-Error "start-relay.ps1 nicht gefunden: $relayScript"
}

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $relayScript) `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Startet das proxy-relay beim Anmelden des Benutzers im Hintergrund.' | Out-Null

Write-Host "Aufgabe '$TaskName' registriert."
Write-Host "Trigger:  Anmeldung von $env:USERDOMAIN\$env:USERNAME"
Write-Host "Ziel:     $relayScript"
Write-Host ""
Write-Host "Sofort testen:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Anzeigen / pruefen:"
Write-Host "  Get-ScheduledTaskInfo -TaskName '$TaskName'"
Write-Host "Entfernen:"
Write-Host "  .\install-autostart.ps1 -Uninstall"
