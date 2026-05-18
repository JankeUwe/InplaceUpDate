#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert den SSIS Integration Services Catalog (SSISDB) als Gesamt-Backup.
.DESCRIPTION
    Führt ein vollständiges Backup der SSISDB-Datenbank durch.
    Zusätzlich wird ein Inventar aller Projekte/Pakete/Environments erstellt.
    
    Der SSISDB-Master-Key wird separat dokumentiert (muss manuell gesichert werden).
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-SSISCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [System.Management.Automation.PSCredential]
        $SqlCredential,

        # Lokaler Pfad auf dem SQL Server für das Backup (SQL Server schreibt selbst)
        [string]$BackupPath
    )

    Write-UpgradeLog "SSISDB Catalog Sicherung gestartet für: $SqlInstance" -Level SECTION

    #region --- Prüfen ob SSISDB vorhanden ---
    try {
        $connectParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }
        $server = Connect-DbaInstance @connectParams

        $ssisdbExists = Invoke-DbaQuery -SqlInstance $server `
            -Query "SELECT name FROM sys.databases WHERE name = 'SSISDB'" |
            Select-Object -ExpandProperty name

        if (-not $ssisdbExists) {
            Write-UpgradeLog "SSISDB nicht vorhanden - SSIS Catalog Sicherung übersprungen." -Level INFO
            return [PSCustomObject]@{ CatalogExists = $false }
        }
        Write-UpgradeLog "SSISDB gefunden - starte Sicherung." -Level INFO
    }
    catch {
        Write-UpgradeLog "Verbindungsfehler: $_" -Level ERROR
        throw
    }
    #endregion

    #region --- Backup Pfad bestimmen ---
    if (-not $BackupPath) {
        # Standard-Backup-Verzeichnis des SQL Servers verwenden
        $defaultBackupDir = Invoke-DbaQuery -SqlInstance $server `
            -Query "SELECT SERVERPROPERTY('InstanceDefaultBackupPath') AS BackupPath" |
            Select-Object -ExpandProperty BackupPath

        if (-not $defaultBackupDir) {
            # Fallback: aus Registry
            $defaultBackupDir = (Get-DbaDefaultPath -SqlInstance $server).Backup
        }

        $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $BackupPath = Join-Path $defaultBackupDir "SSISDB_Upgrade_$timestamp.bak"
    }

    Write-UpgradeLog "Backup-Ziel (auf SQL Server): $BackupPath" -Level INFO
    #endregion

    #region --- SSISDB Backup durchführen ---
    Write-UpgradeLog "Starte SSISDB Datenbank-Backup..." -Level INFO

    try {
        $backupResult = Backup-DbaDatabase `
            -SqlInstance   $server `
            -Database      'SSISDB' `
            -FilePath      $BackupPath `
            -Type          Full `
            -CompressBackup `
            -Checksum `
            -Verify

        if ($backupResult) {
            Write-UpgradeLog "SSISDB Backup erfolgreich: $BackupPath" -Level SUCCESS
            Write-UpgradeLog "Backup-Größe: $([math]::Round($backupResult.BackupSizeMB, 2)) MB" -Level INFO
        }
        else {
            Write-UpgradeLog "SSISDB Backup - kein Ergebnis erhalten, bitte manuell prüfen!" -Level WARN
        }
    }
    catch {
        Write-UpgradeLog "SSISDB Backup fehlgeschlagen: $_" -Level ERROR

        # Fallback: manuelles T-SQL Backup
        Write-UpgradeLog "Versuche manuelles T-SQL Backup..." -Level INFO
        try {
            $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupSQL  = @"
BACKUP DATABASE [SSISDB]
TO DISK = N'$BackupPath'
WITH COMPRESSION, CHECKSUM, STATS = 10,
     DESCRIPTION = N'SSISDB Upgrade Backup $timestamp'
"@
            Invoke-DbaQuery -SqlInstance $server -Query $backupSQL -QueryTimeout 3600
            Write-UpgradeLog "Manuelles Backup abgeschlossen." -Level SUCCESS
        }
        catch {
            Write-UpgradeLog "Auch manuelles Backup fehlgeschlagen: $_" -Level ERROR
            throw
        }
    }

    # Backup-Pfad für Bericht speichern
    $backupInfoFile = Join-Path $OutputPath 'SSISDB_Backup_Info.txt'
    @"
SSISDB Backup Information
=========================
Instanz    : $SqlInstance
Erstellt   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Backup-Pfad: $BackupPath

Wiederherstellung:
------------------
1. Neue SQL Server Instanz installieren
2. SSISDB Catalog erstellen (falls noch nicht vorhanden):
   EXEC [SSISDB].[catalog].[create_catalog] @password = N'<CATALOG_PASSWORT>'
3. SSISDB Datenbank wiederherstellen:
   RESTORE DATABASE [SSISDB]
   FROM DISK = N'$BackupPath'
   WITH REPLACE, RECOVERY
4. Nach Restore den Catalog upgraden:
   EXEC [SSISDB].[catalog].[upgrade_project] (falls Version-Unterschied)

WICHTIG: Den SSISDB-Master-Key und das Catalog-Passwort sicher aufbewahren!
"@ | Out-File -FilePath $backupInfoFile -Encoding UTF8
    #endregion

    #region --- Inventar: Projekte, Pakete, Environments ---
    Write-UpgradeLog "Erstelle SSISDB Inventar..." -Level INFO

    $inventarQueries = @{
        Folders = @"
SELECT folder_name, description, created_time
FROM SSISDB.catalog.folders
ORDER BY folder_name
"@
        Projects = @"
SELECT f.folder_name, p.name AS project_name, p.description,
       p.deployed_by_name, p.last_deployed_time,
       p.object_version_lsn AS version
FROM SSISDB.catalog.projects p
JOIN SSISDB.catalog.folders  f ON p.folder_id = f.folder_id
ORDER BY f.folder_name, p.name
"@
        Packages = @"
SELECT f.folder_name, pr.name AS project_name, pk.name AS package_name,
       pk.description, pk.version_major, pk.version_minor, pk.version_build
FROM SSISDB.catalog.packages pk
JOIN SSISDB.catalog.projects pr ON pk.project_id = pr.project_id
JOIN SSISDB.catalog.folders  f  ON pr.folder_id  = f.folder_id
ORDER BY f.folder_name, pr.name, pk.name
"@
        Environments = @"
SELECT f.folder_name, e.name AS environment_name, e.description
FROM SSISDB.catalog.environments e
JOIN SSISDB.catalog.folders      f ON e.folder_id = f.folder_id
ORDER BY f.folder_name, e.name
"@
        EnvironmentVariables = @"
SELECT f.folder_name, e.name AS environment_name,
       ev.name AS variable_name, ev.type,
       ev.sensitive AS is_sensitive,
       CASE WHEN ev.sensitive = 1 THEN '*** SENSITIV - NICHT EXPORTIERBAR ***'
            ELSE CAST(ev.value AS NVARCHAR(MAX)) END AS value,
       ev.description
FROM SSISDB.catalog.environment_variables ev
JOIN SSISDB.catalog.environments e ON ev.environment_id = e.environment_id
JOIN SSISDB.catalog.folders      f ON e.folder_id = f.folder_id
ORDER BY f.folder_name, e.name, ev.name
"@
    }

    $inventar = @{}
    foreach ($key in $inventarQueries.Keys) {
        try {
            $inventar[$key] = Invoke-DbaQuery -SqlInstance $server -Query $inventarQueries[$key]
            $csvPath = Join-Path $OutputPath "SSISDB_Inventar_$key.csv"
            $inventar[$key] | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            Write-UpgradeLog "Inventar [$key]: $($inventar[$key].Count) Einträge" -Level INFO
        }
        catch {
            Write-UpgradeLog "Fehler beim Inventar [$key]: $_" -Level WARN
        }
    }
    #endregion

    #region --- Warnung wegen sensitiver Variablen ---
    $sensitiveVars = ($inventar['EnvironmentVariables'] | Where-Object { $_.is_sensitive }).Count
    if ($sensitiveVars -gt 0) {
        Write-UpgradeLog "HINWEIS: $sensitiveVars sensitive Environment-Variable(n) können nicht exportiert werden und müssen nach der Wiederherstellung manuell gesetzt werden!" -Level WARN
    }
    #endregion

    Write-UpgradeLog "SSISDB Catalog Sicherung abgeschlossen." -Level SUCCESS

    return [PSCustomObject]@{
        CatalogExists      = $true
        BackupPath         = $BackupPath
        BackupInfoFile     = $backupInfoFile
        FolderCount        = $inventar['Folders'].Count
        ProjectCount       = $inventar['Projects'].Count
        PackageCount       = $inventar['Packages'].Count
        EnvironmentCount   = $inventar['Environments'].Count
        SensitiveVarCount  = $sensitiveVars
    }
}
