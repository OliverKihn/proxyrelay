# Einmalige Einrichtung: AD-Zugangsdaten fuer proxy-relay verschluesselt ablegen.
# Verschluesselung: Windows DPAPI (CurrentUser) - entschluesselbar nur durch
# diesen Windows-Benutzer auf diesem Rechner.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$credDir  = Join-Path $env:APPDATA 'proxy-relay'
$userFile = Join-Path $credDir 'user.txt'
$passFile = Join-Path $credDir 'pass.dpapi'

if (-not (Test-Path $credDir)) {
    New-Item -ItemType Directory -Path $credDir -Force | Out-Null
}

$user = Read-Host 'Benutzername (z.B. domain\username)'
if ([string]::IsNullOrWhiteSpace($user)) {
    Write-Error 'Benutzername darf nicht leer sein.'
}

$secure = Read-Host -AsSecureString 'AD-Passwort'
if ($secure.Length -eq 0) {
    Write-Error 'Passwort darf nicht leer sein.'
}

# DPAPI-Verschluesselung (Default-Scope: CurrentUser)
$encrypted = ConvertFrom-SecureString -SecureString $secure

Set-Content -Path $userFile -Value $user.Trim() -Encoding UTF8 -NoNewline
Set-Content -Path $passFile -Value $encrypted   -Encoding UTF8 -NoNewline

# ACL haerten: Vererbung aus, nur aktueller User hat Vollzugriff
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl = Get-Acl $credDir
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $identity, 'FullControl',
    'ContainerInherit,ObjectInherit', 'None', 'Allow'
)
$acl.AddAccessRule($rule)
Set-Acl -Path $credDir -AclObject $acl

Write-Host ""
Write-Host "Credentials gespeichert in: $credDir"
Write-Host "Verschluesselt mit DPAPI - entschluesselbar nur als $env:USERNAME auf $env:COMPUTERNAME."
