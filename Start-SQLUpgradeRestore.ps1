#Requires -Version 5.1
#Requires -Modules dbatools
<#
.SYNOPSIS
    SQL Server Upgrade - Wiederherstellungs-Einstiegspunkt.
.DESCRIPTION
    Stellt alle gesicherten Objekte nach der SQL Server Neuinstallation wieder her.
    Jeder Schritt wird interaktiv bestätigt.

.PARAMETER SqlInstance
    Neue SQL Server Instanz (nach Neu-Installation).

.PARAMETER BackupSetPath
    Pfad zum Backup-Set-Verzeichnis (z.B. C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER)

.EXAMPLE
    .\Start-SQLUpgradeRestore.ps1 -SqlInstance localhost -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SqlInstance,

    [Parameter(Mandatory)]
    [string]$BackupSetPath,

    [System.Management.Automation.PSCredential]$SqlCredential,
    [string]$SSASServer,
    [string]$SSRSReportServerDB = 'ReportServer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$moduleBase = $PSScriptRoot

. "$moduleBase\Modules\Common\Write-UpgradeLog.ps1"
. "$moduleBase\Modules\Restore-SQLObjects.ps1"

# Log in das Backup-Set-Verzeichnis schreiben
$restoreLog = Join-Path $BackupSetPath "Restore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Global:UpgradeLogFile = $restoreLog

Write-UpgradeLog "SQL Server Upgrade Wiederherstellung gestartet" -Level SECTION
Write-UpgradeLog "Neue Instanz  : $SqlInstance"   -Level INFO
Write-UpgradeLog "Backup-Set    : $BackupSetPath" -Level INFO

$restoreParams = @{
    SqlInstance         = $SqlInstance
    BackupSetPath       = $BackupSetPath
    SSRSReportServerDB  = $SSRSReportServerDB
}
if ($SqlCredential) { $restoreParams.SqlCredential = $SqlCredential }
if ($SSASServer)    { $restoreParams.SSASServer    = $SSASServer    }

$results = Start-SQLRestore @restoreParams

$resultsFile = Join-Path $BackupSetPath "Restore_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$results | ConvertTo-Json -Depth 5 | Out-File $resultsFile -Encoding UTF8

Write-Host ""
Write-Host "Wiederherstellung abgeschlossen. Details: $restoreLog" -ForegroundColor Green
