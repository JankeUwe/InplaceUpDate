#Requires -Version 5.1
<#
.SYNOPSIS
    SQL Server Upgrade - Deinstallations-Einstiegspunkt.
.DESCRIPTION
    Deinstalliert SQL Server nach erfolgreicher Sicherung.
    Prüft ob eine Sicherung vorhanden ist bevor die Deinstallation gestartet wird.

.PARAMETER InstanceName
    Zu deinstallierende Instanz. Standard: MSSQLSERVER

.PARAMETER BackupSetPath
    Pfad zum abgeschlossenen Backup-Set (Pflicht als Nachweis der Sicherung).

.PARAMETER SetupPath
    Pfad zu setup.exe. Falls leer: automatische Suche.

.EXAMPLE
    .\Start-SQLUpgradeUninstall.ps1 -InstanceName MSSQLSERVER -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'
#>

[CmdletBinding()]
param(
    [string]$InstanceName  = 'MSSQLSERVER',
    [Parameter(Mandatory)]
    [string]$BackupSetPath,
    [string]$SetupPath,
    [string[]]$Features,
    [switch]$SkipCleanup,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleBase = $PSScriptRoot

. "$moduleBase\Modules\Common\Write-UpgradeLog.ps1"
. "$moduleBase\Modules\Invoke-SQLUninstall.ps1"

#region --- Backup-Set prüfen ---
if (-not (Test-Path $BackupSetPath)) {
    Write-Host "FEHLER: Backup-Set-Verzeichnis nicht gefunden: $BackupSetPath" -ForegroundColor Red
    Write-Host "Bitte zuerst Start-SQLUpgradeBackup.ps1 ausführen!" -ForegroundColor Red
    exit 1
}

$summaryFile = Join-Path $BackupSetPath 'Backup_Summary.json'
if (-not (Test-Path $summaryFile)) {
    Write-Host "WARNUNG: Keine Backup_Summary.json in '$BackupSetPath' gefunden." -ForegroundColor Yellow
    Write-Host "Sicherung möglicherweise unvollständig!" -ForegroundColor Yellow

    $continue = Invoke-WithConfirmation `
        -Message "Ohne verifizierten Backup-Nachweis fortfahren?" `
        -WarningDetail "Risiko: Datenverlust wenn Sicherung unvollständig war!" `
        -Type YesNo

    if (-not $continue) { exit 0 }
}
else {
    Write-Host "Backup-Nachweis gefunden: $summaryFile" -ForegroundColor Green
}
#endregion

# Log in das Backup-Set-Verzeichnis
$Global:UpgradeLogFile = Join-Path $BackupSetPath "Uninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$uninstallParams = @{
    InstanceName = $InstanceName
    OutputPath   = $BackupSetPath
}
if ($SetupPath)    { $uninstallParams.SetupPath    = $SetupPath    }
if ($Features)     { $uninstallParams.Features     = $Features     }
if ($SkipCleanup)  { $uninstallParams.SkipCleanup  = $true         }
if ($NoRestart)    { $uninstallParams.NoRestart    = $true         }

Invoke-SQLUninstall @uninstallParams
