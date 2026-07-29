#Requires -Version 5.1
#Requires -Modules dbatools
<#
.SYNOPSIS
    Geführter Wizard für den kompletten SQL Server Inplace-Upgrade-Ablauf.
.DESCRIPTION
    Führt interaktiv durch:
    1. Sicherung aller Objekte (Logins, Linked Server, SSIS, SSRS, SSAS)
    2. Deinstallation von SQL Server
    3. Wiederherstellung nach der manuellen Neuinstallation

    Fragt alle nötigen Werte mit sinnvollen Standardwerten ab (siehe
    Modules\Common\Wizard-UI.ps1) und merkt sich den Fortschritt über einen
    Neustart hinweg (siehe Modules\Common\WizardState.ps1), da zwischen
    Deinstallation und Wiederherstellung die neue SQL Server Version manuell
    installiert werden muss.

    Ruft ausschliesslich die bestehenden Backup-/Uninstall-/Restore-Skripte
    und -Module auf - es wird keine Fachlogik dupliziert.

.EXAMPLE
    .\Start-SQLUpgradeWizard.ps1
#>

[CmdletBinding()]
param()

# Konsolen-Ausgabe auf UTF-8 setzen, damit Umlaute (ü, ä, ö, ß) nicht als
# Schmierzeichen erscheinen (PowerShell 5.1 Standard-Codepage passt sonst
# nicht zur UTF-8-Kodierung dieser Skriptdateien).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleBase = $PSScriptRoot

. "$moduleBase\Modules\Common\Write-UpgradeLog.ps1"
. "$moduleBase\Modules\Common\Wizard-UI.ps1"
. "$moduleBase\Modules\Common\WizardState.ps1"
. "$moduleBase\Modules\Invoke-SQLUninstall.ps1"
. "$moduleBase\Modules\Restore-SQLObjects.ps1"

$TotalSteps = 3

Write-Host ""
Write-Host ('=' * 80) -ForegroundColor Magenta
Write-Host "  SQL Server Inplace-Upgrade Wizard" -ForegroundColor Magenta
Write-Host ('=' * 80) -ForegroundColor Magenta
Write-Host ""
Write-Host "Führt Sie durch:" -ForegroundColor White
Write-Host "  1. Sicherung aller Objekte (Logins, Linked Server, SSIS, SSRS, SSAS)"
Write-Host "  2. Deinstallation von SQL Server"
Write-Host "  3. Wiederherstellung nach der manuellen Neuinstallation"
Write-Host ""
Write-Host "Achtung: Schritt 2 verändert die Systemkonfiguration dauerhaft." -ForegroundColor Yellow
Write-Host ""

#region --- Vorherige Sitzung erkennen ---
$state = Get-WizardState

if ($state) {
    Write-Host "Es wurde eine vorherige Sitzung gefunden:" -ForegroundColor Cyan
    Write-Host "  Instanz       : $($state.SqlInstance) ($($state.InstanceName))"
    Write-Host "  Backup-Set    : $($state.BackupSetPath)"
    Write-Host "  Phase         : $($state.Phase)"
    Write-Host "  Zuletzt aktiv : $($state.LastUpdatedAt)"
    Write-Host ""

    $resume = Read-WizardYesNo -Prompt "Diese Sitzung fortsetzen?" -Default J
    if (-not $resume) { $state = $null }
}
#endregion

try {
    if (-not $state -or $state.Phase -eq 'New') {
        #region --- Phase 1: Sicherung ---
        Show-WizardStep -Number 1 -Total $TotalSteps -Title 'Sicherung'

        $instances = @(Get-LocalSQLInstances)
        $instanceChoiceOptions = @()
        foreach ($inst in $instances) {
            $instanceChoiceOptions += [PSCustomObject]@{
                Label = "$($inst.SqlInstance) ($($inst.InstanceName))"
                Value = $inst
            }
        }

        $selectedInstance = $null
        if ($instanceChoiceOptions.Count -gt 0) {
            $selectedInstance = Read-WizardChoice -Prompt "Gefundene lokale SQL Server Instanzen:" `
                -Options $instanceChoiceOptions -DefaultIndex 1 `
                -AllowCustom -CustomLabel 'Andere Instanz manuell eingeben'
        }

        if ($selectedInstance) {
            $sqlInstance  = $selectedInstance.SqlInstance
            $instanceName = $selectedInstance.InstanceName
        }
        else {
            $sqlInstance  = Read-WizardText -Prompt "SQL Server Instanz" -Default 'localhost'
            $instanceName = Read-WizardText -Prompt "Interner Instanzname (für Deinstallation)" -Default 'MSSQLSERVER'
        }

        $outputBaseDir = Read-WizardText -Prompt "Ausgabeverzeichnis für die Sicherung" -Default 'C:\SQLUpgrade_Backup'
        $sqlCredential = Read-WizardCredential -InstanceLabel $sqlInstance

        $skipSSAS   = Read-WizardYesNo -Prompt "SSAS-Sicherung überspringen?" -Default N
        $ssasServer = $null
        if (-not $skipSSAS) {
            $ssasServer = Read-WizardText -Prompt "SSAS-Server (falls abweichend von '$sqlInstance', sonst leer lassen)" -AllowEmpty
        }

        $skipSSRS = Read-WizardYesNo -Prompt "SSRS-Sicherung überspringen?" -Default N
        $ssrsDb   = 'ReportServer'
        if (-not $skipSSRS) {
            $ssrsDb = Read-WizardText -Prompt "SSRS ReportServer-Datenbankname" -Default 'ReportServer'
        }

        Write-Host ""
        Write-Host "Zusammenfassung:" -ForegroundColor Cyan
        Write-Host "  Instanz             : $sqlInstance ($instanceName)"
        Write-Host "  Ausgabeverzeichnis  : $outputBaseDir"
        Write-Host "  Auth                : $(if ($sqlCredential) { 'SQL-Auth: ' + $sqlCredential.UserName } else { 'Windows-Auth' })"
        Write-Host "  SSAS überspringen   : $skipSSAS"
        Write-Host "  SSRS überspringen   : $skipSSRS"
        Write-Host ""

        $confirmed = Read-WizardYesNo -Prompt "Sicherung mit diesen Werten starten?" -Default J
        if (-not $confirmed) {
            Write-UpgradeLog "Sicherung durch Benutzer abgebrochen." -Level WARN
            return
        }

        $backupParams = @{
            SqlInstance        = $sqlInstance
            OutputBaseDir      = $outputBaseDir
            InstanceName       = $instanceName
            SSRSReportServerDB = $ssrsDb
        }
        if ($sqlCredential) { $backupParams.SqlCredential = $sqlCredential }
        if ($ssasServer)    { $backupParams.SSASServer    = $ssasServer }
        if ($skipSSAS)      { $backupParams.SkipSSAS      = $true }
        if ($skipSSRS)      { $backupParams.SkipSSRS      = $true }

        . "$moduleBase\Start-SQLUpgradeBackup.ps1" @backupParams

        $state = New-WizardState -Phase 'BackupDone' `
            -SqlInstance $sqlInstance -InstanceName $instanceName `
            -OutputBaseDir $outputBaseDir -BackupSetPath $outRoot `
            -SSASServer $ssasServer -SSRSReportServerDB $ssrsDb

        Save-WizardState -State $state
        #endregion
    }

    if ($state.Phase -eq 'BackupDone') {
        #region --- Phase 2: Deinstallation ---
        Show-WizardStep -Number 2 -Total $TotalSteps -Title 'Deinstallation'

        Write-Host "Übernommenes Backup-Set: $($state.BackupSetPath)" -ForegroundColor Cyan
        $useStoredPath = Read-WizardYesNo -Prompt "Dieses Backup-Set für die Deinstallation verwenden?" -Default J
        $backupSetPath = if ($useStoredPath) {
            $state.BackupSetPath
        }
        else {
            Read-WizardText -Prompt "Pfad zum Backup-Set" `
                -Validate { Test-Path $args[0] } -ValidationMessage 'Verzeichnis nicht gefunden.'
        }

        $summaryFile = Join-Path $backupSetPath 'Backup_Summary.json'
        if (-not (Test-Path $summaryFile)) {
            $proceedWithoutProof = Read-WizardYesNo `
                -Prompt "WARNUNG: Keine Backup_Summary.json gefunden - ohne verifizierten Sicherungsnachweis fortfahren?" `
                -Default N
            if (-not $proceedWithoutProof) {
                Write-UpgradeLog "Deinstallation abgebrochen - kein Sicherungsnachweis." -Level WARN
                return
            }
        }

        $instanceNameForUninstall = Read-WizardText -Prompt "Zu deinstallierende Instanz" -Default $state.InstanceName

        $Global:UpgradeLogFile = Join-Path $backupSetPath "Uninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        # Zustand VOR dem Aufruf sichern: Invoke-SQLUninstall kann bei bestätigtem
        # Neustart den Prozess sofort beenden (Restart-Computer) - Deinstallation
        # und Cleanup sind zu diesem Zeitpunkt bereits abgeschlossen.
        $state.Phase         = 'UninstallDone'
        $state.BackupSetPath = $backupSetPath
        Save-WizardState -State $state

        Invoke-SQLUninstall -InstanceName $instanceNameForUninstall -OutputPath $backupSetPath

        Write-Host ""
        Write-Host "Deinstallation abgeschlossen (falls kein Neustart erfolgt ist)." -ForegroundColor Green
        Wait-ForWizardContinue -Message "Installieren Sie jetzt die neue SQL Server Version manuell. Danach hier fortfahren."
        #endregion
    }

    if ($state.Phase -eq 'UninstallDone') {
        #region --- Phase 3: Wiederherstellung ---
        Show-WizardStep -Number 3 -Total $TotalSteps -Title 'Wiederherstellung'

        $newSqlInstance    = Read-WizardText -Prompt "Neue SQL Server Instanz (nach Neuinstallation)" -Default $state.SqlInstance
        $restoreCredential = Read-WizardCredential -InstanceLabel $newSqlInstance

        $backupSetPath = $state.BackupSetPath
        Write-Host "Backup-Set: $backupSetPath" -ForegroundColor Cyan
        if (-not (Test-Path $backupSetPath)) {
            $backupSetPath = Read-WizardText -Prompt "Pfad zum Backup-Set" `
                -Validate { Test-Path $args[0] } -ValidationMessage 'Verzeichnis nicht gefunden.'
        }

        $Global:UpgradeLogFile = Join-Path $backupSetPath "Restore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        $restoreParams = @{
            SqlInstance        = $newSqlInstance
            BackupSetPath      = $backupSetPath
            SSRSReportServerDB = $state.SSRSReportServerDB
        }
        if ($restoreCredential) { $restoreParams.SqlCredential = $restoreCredential }
        if ($state.SSASServer)  { $restoreParams.SSASServer    = $state.SSASServer }

        $results = Start-SQLRestore @restoreParams

        $resultsFile = Join-Path $backupSetPath "Restore_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $results | ConvertTo-Json -Depth 5 | Out-File $resultsFile -Encoding UTF8

        $state.Phase       = 'RestoreDone'
        $state.SqlInstance = $newSqlInstance
        Save-WizardState -State $state

        Write-Host ""
        Write-Host "Wiederherstellung abgeschlossen." -ForegroundColor Green
        Write-Host "Log     : $Global:UpgradeLogFile" -ForegroundColor White
        Write-Host "Ergebnis: $resultsFile" -ForegroundColor White
        #endregion
    }

    if ($state.Phase -eq 'RestoreDone') {
        Write-Host ""
        Write-Host "Wizard abgeschlossen." -ForegroundColor Green
    }
}
catch {
    Write-UpgradeLog "Wizard abgebrochen: $_" -Level ERROR
    throw
}
