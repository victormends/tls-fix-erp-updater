#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$UpdaterPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$Message) Write-Host "[ok]   $Message" -ForegroundColor Green }
function Write-Bad  { param([string]$Message) Write-Host "[fail] $Message" -ForegroundColor Red }

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-DenySetValueRule {
    param(
        [string]$RegistryPath,
        [string]$UserName
    )

    $acl = Get-Acl $RegistryPath
    $rule = New-Object Security.AccessControl.RegistryAccessRule($UserName, 'SetValue', 'Deny')
    $acl.AddAccessRule($rule)
    Set-Acl $RegistryPath $acl
}

function Remove-DenySetValueRules {
    param(
        [string]$RegistryPath,
        [string]$UserName
    )

    $acl = Get-Acl $RegistryPath
    $rulesToRemove = @(
        $acl.Access | Where-Object {
            $_.IdentityReference -eq $UserName -and
            $_.RegistryRights -eq 'SetValue' -and
            $_.AccessControlType -eq 'Deny'
        }
    )

    foreach ($rule in $rulesToRemove) {
        [void]$acl.RemoveAccessRule($rule)
    }

    Set-Acl $RegistryPath $acl
}

if (-not (Test-Path $UpdaterPath -PathType Leaf)) {
    throw "Updater not found: $UpdaterPath"
}

if (-not (Test-IsAdministrator)) {
    Write-Info 'Elevation required. Relaunching with administrator privileges...'

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        "`"$PSCommandPath`""
        '-UpdaterPath'
        "`"$UpdaterPath`""
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs | Out-Null
    exit 0
}

$registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
# 2048 = 0x0800 = TLS 1.2 only. The updater was observed resetting this to a
# legacy protocol mask during startup, breaking modern fiscal endpoints.
$tls12Only = 2048
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$lockApplied = $false
$updaterProcess = $null

try {
    Write-Info "Pinning TLS 1.2 in '$registryPath'..."
    Set-ItemProperty -Path $registryPath -Name 'SecureProtocols' -Value $tls12Only -Type DWord -Force

    Write-Info "Locking '$registryPath' against updater writes..."
    Add-DenySetValueRule -RegistryPath $registryPath -UserName $currentUser
    $lockApplied = $true

    Write-Info "Launching updater: $UpdaterPath"
    $updaterProcess = Start-Process -FilePath $UpdaterPath -PassThru
    $updaterProcess.WaitForExit()

    if ($updaterProcess.ExitCode -eq 0) {
        Write-Ok "Updater exited successfully with code $($updaterProcess.ExitCode)."
    }
    else {
        Write-Bad "Updater exited with code $($updaterProcess.ExitCode)."
        exit $updaterProcess.ExitCode
    }
}
finally {
    if (-not $lockApplied) {
        return
    }

    Write-Info 'Removing registry lock and restoring write access...'

    try {
        Remove-DenySetValueRules -RegistryPath $registryPath -UserName $currentUser
        Write-Ok 'Registry access restored.'
    }
    catch {
        Write-Bad "Failed to remove registry lock: $($_.Exception.Message)"
        throw
    }
}

Write-Ok 'Done.'
