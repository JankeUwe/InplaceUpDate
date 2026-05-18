#Requires -Version 5.1
#Requires -Modules dbatools
<#
.SYNOPSIS
    SQL Server Upgrade - Sicherungs-Einstiegspunkt.
.DESCRIPTION
    Führt alle Sicherungsschritte vor einem SQL Server Inplace-Upgrade durch:
    1.  Abhängigkeitsprüfung (ODBC, OLE DB, Visual Studio)
    2.  Login-Sicherung (inkl. Passwort-Hashes)
    3.  Linked Server Sicherung
    4.  SSIS Legacy-Pakete (msdb)
    5.  SSISDB Catalog Backup
    6.  SSRS Inhalte und Konfiguration
    7.  SSAS Datenbanken
    
.PARAMETER SqlInstance
    SQL Server Instanz. Standard: localhost (Standardinstanz)
    Benannte Instanz: 'SERVER\INSTANZNAME'
    
.PARAMETER OutputBaseDir
    Basisverzeichnis für die Sicherungs-Ausgabe.
    Standard: C:\SQLUpgrade_Backup

.PARAMETER InstanceName
    Interner Instanzname für Deinstallation.
    Standard: 'MSSQLSERVER' (Standardinstanz)

.PARAMETER SSASServer
    SSAS-Server falls abweichend vom SQL Server.

.PARAMETER SSRSReportServerDB
    Name der ReportServer-Datenbank. Standard: 'ReportServer'

.PARAMETER SqlCredential
    Credential für SQL-Authentifizierung. Ohne Angabe: Windows-Auth.

.PARAMETER SSISDBBackupPath
    Lokaler Pfad auf dem SQL Server für das SSISDB-Backup.
    Standard: Standard-Backup-Verzeichnis der Instanz.

.EXAMPLE
    # Standardinstanz, Windows-Auth
    .\Start-SQLUpgradeBackup.ps1 -SqlInstance localhost

.EXAMPLE
    # Benannte Instanz
    .\Start-SQLUpgradeBackup.ps1 -SqlInstance 'SERVER01\SQL2019' -InstanceName 'SQL2019'

.EXAMPLE
    # Mit SQL-Auth und benutzerdefiniertem Ausgabepfad
    $cred = Get-Credential
    .\Start-SQLUpgradeBackup.ps1 -SqlInstance localhost -SqlCredential $cred -OutputBaseDir 'D:\Backup'
#>

[CmdletBinding()]
param(
    [string]$SqlInstance      = 'localhost',
    [string]$OutputBaseDir    = 'C:\SQLUpgrade_Backup',
    [string]$InstanceName     = 'MSSQLSERVER',
    [string]$SSASServer,
    [string]$SSRSReportServerDB = 'ReportServer',
    [System.Management.Automation.PSCredential]$SqlCredential,
    [string]$SSISDBBackupPath,
    [switch]$SkipDependencyCheck,
    [switch]$SkipSSAS,
    [switch]$SkipSSRS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Module laden ---
$moduleBase = $PSScriptRoot

. "$moduleBase\Modules\Common\Write-UpgradeLog.ps1"
. "$moduleBase\Modules\Test-SQLDependencies.ps1"
. "$moduleBase\Modules\Backup-SQLLogins.ps1"
. "$moduleBase\Modules\Backup-LinkedServers.ps1"
. "$moduleBase\Modules\Backup-SSISLegacy.ps1"
. "$moduleBase\Modules\Backup-SSISCatalog.ps1"
. "$moduleBase\Modules\Backup-SSRSContent.ps1"
. "$moduleBase\Modules\Backup-SSASContent.ps1"
#endregion

#region --- Ausgabeverzeichnis initialisieren ---
$logInit = Initialize-UpgradeLog -BaseOutputPath $OutputBaseDir -InstanceName $InstanceName
$outRoot = $logInit.OutputRoot

Write-UpgradeLog "SQL Server Upgrade Sicherung gestartet" -Level SECTION
Write-UpgradeLog "Instanz       : $SqlInstance ($InstanceName)" -Level INFO
Write-UpgradeLog "Ausgabe       : $outRoot"                     -Level INFO
Write-UpgradeLog "Gestartet von : $env:USERDOMAIN\$env:USERNAME" -Level INFO
Write-UpgradeLog "Rechner       : $env:COMPUTERNAME"            -Level INFO
#endregion

$summary = [ordered]@{}
$aborted  = $false

try {

    #region --- Schritt 1: Abhängigkeitsprüfung ---
    if (-not $SkipDependencyCheck) {
        $depResult = Test-SQLDependencies `
            -InstanceName $InstanceName `
            -OutputPath   (Join-Path $outRoot 'Dependencies')

        $summary['Dependencies'] = $depResult

        if (-not $depResult.CanProceed) {
            Write-UpgradeLog "Sicherung abgebrochen wegen Abhängigkeiten." -Level WARN
            $aborted = $true
        }
    }
    #endregion

    if (-not $aborted) {

        $connectParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }

        #region --- Schritt 2: Logins ---
        Write-UpgradeLog "Schritt 2: Login-Sicherung" -Level SECTION
        try {
            $loginResult = Backup-SQLLogins @connectParams `
                -OutputPath      (Join-Path $outRoot 'Logins') `
                -IncludeDisabled
            $summary['Logins'] = $loginResult
        }
        catch {
            Write-UpgradeLog "Login-Sicherung fehlgeschlagen: $_" -Level ERROR
            $summary['Logins'] = @{ Status = 'ERROR'; Error = $_.ToString() }
        }
        #endregion

        #region --- Schritt 3: Linked Server ---
        Write-UpgradeLog "Schritt 3: Linked Server Sicherung" -Level SECTION
        try {
            $lsResult = Backup-LinkedServers @connectParams `
                -OutputPath (Join-Path $outRoot 'LinkedServers')
            $summary['LinkedServers'] = $lsResult
        }
        catch {
            Write-UpgradeLog "Linked Server Sicherung fehlgeschlagen: $_" -Level ERROR
            $summary['LinkedServers'] = @{ Status = 'ERROR'; Error = $_.ToString() }
        }
        #endregion

        #region --- Schritt 4: SSIS Legacy ---
        Write-UpgradeLog "Schritt 4: SSIS Legacy (msdb) Sicherung" -Level SECTION
        try {
            $ssisLegResult = Backup-SSISLegacy @connectParams `
                -OutputPath (Join-Path $outRoot 'SSIS_Legacy')
            $summary['SSISLegacy'] = $ssisLegResult
        }
        catch {
            Write-UpgradeLog "SSIS Legacy Sicherung fehlgeschlagen: $_" -Level ERROR
            $summary['SSISLegacy'] = @{ Status = 'ERROR'; Error = $_.ToString() }
        }
        #endregion

        #region --- Schritt 5: SSISDB Catalog ---
        Write-UpgradeLog "Schritt 5: SSISDB Catalog Sicherung" -Level SECTION
        try {
            $ssisCatParams = @{}
            if ($SSISDBBackupPath) { $ssisCatParams.BackupPath = $SSISDBBackupPath }

            $ssisCatResult = Backup-SSISCatalog @connectParams @ssisCatParams `
                -OutputPath (Join-Path $outRoot 'SSIS_Catalog')
            $summary['SSISCatalog'] = $ssisCatResult
        }
        catch {
            Write-UpgradeLog "SSISDB Catalog Sicherung fehlgeschlagen: $_" -Level ERROR
            $summary['SSISCatalog'] = @{ Status = 'ERROR'; Error = $_.ToString() }
        }
        #endregion

        #region --- Schritt 6: SSRS ---
        if (-not $SkipSSRS) {
            Write-UpgradeLog "Schritt 6: SSRS Sicherung" -Level SECTION
            try {
                $ssrsResult = Backup-SSRSContent @connectParams `
                    -OutputPath       (Join-Path $outRoot 'SSRS') `
                    -ReportServerDB   $SSRSReportServerDB
                $summary['SSRS'] = $ssrsResult
            }
            catch {
                Write-UpgradeLog "SSRS Sicherung fehlgeschlagen: $_" -Level ERROR
                $summary['SSRS'] = @{ Status = 'ERROR'; Error = $_.ToString() }
            }
        }
        #endregion

        #region --- Schritt 7: SSAS ---
        if (-not $SkipSSAS) {
            Write-UpgradeLog "Schritt 7: SSAS Sicherung" -Level SECTION
            try {
                $ssasParams = @{}
                if ($SSASServer) { $ssasParams.SSASServer = $SSASServer }

                $ssasResult = Backup-SSASContent `
                    -SqlInstance $SqlInstance `
                    -OutputPath  (Join-Path $outRoot 'SSAS') `
                    @ssasParams
                $summary['SSAS'] = $ssasResult
            }
            catch {
                Write-UpgradeLog "SSAS Sicherung fehlgeschlagen: $_" -Level ERROR
                $summary['SSAS'] = @{ Status = 'ERROR'; Error = $_.ToString() }
            }
        }
        #endregion

        #region --- Abschlussbericht ---
        Write-UpgradeLog "=== Sicherungs-Zusammenfassung ===" -Level SECTION

        foreach ($key in $summary.Keys) {
            $val = $summary[$key]
            $status = if ($val.Status)      { $val.Status }
                      elseif ($val.CanProceed -ne $null) { if($val.CanProceed){'OK'}else{'WARN'} }
                      else { 'OK' }
            Write-UpgradeLog "$key : $status" -Level $(if($status -eq 'ERROR'){'ERROR'}elseif($status -eq 'WARN'){'WARN'}else{'SUCCESS'})
        }

        Write-UpgradeLog "Alle Sicherungen abgeschlossen." -Level SUCCESS
        Write-UpgradeLog "Ausgabeverzeichnis: $outRoot"   -Level INFO
        Write-Host ""
        Write-Host "Sicherung abgeschlossen: $outRoot" -ForegroundColor Green
        #endregion

    }
}
catch {
    Write-UpgradeLog "Kritischer Fehler in Sicherungs-Ablauf: $_" -Level ERROR
    throw
}
finally {
    # Summary als JSON speichern
    $summaryFile = Join-Path $outRoot 'Backup_Summary.json'
    $summary | ConvertTo-Json -Depth 5 | Out-File $summaryFile -Encoding UTF8
}
