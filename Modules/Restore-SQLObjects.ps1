#Requires -Version 5.1
<#
.SYNOPSIS
    Interaktive Wiederherstellung der gesicherten SQL Server Objekte.
.DESCRIPTION
    Stellt nach der Neu-Installation folgende Objekte wieder her:
    - Logins (mit Passwort-Hashes)
    - Linked Server
    - SSIS Legacy-Pakete (msdb)
    - SSISDB Catalog (über Datenbank-Restore)
    - SSRS Inhalte
    - SSAS Datenbanken
    
    Jeder Schritt wird einzeln bestätigt.
    Bereits vorhandene Objekte werden nicht überschrieben (mit Warnung).
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Start-SQLRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,           # Neue SQL Server Instanz

        [Parameter(Mandatory)]
        [string]$BackupSetPath,         # Pfad zum Backup-Set (Output-Verzeichnis vom Backup)

        [System.Management.Automation.PSCredential]
        $SqlCredential,

        [string]$SSASServer,            # SSAS-Server falls abweichend
        [string]$SSRSReportServerDB = 'ReportServer'
    )

    Write-UpgradeLog "SQL Server Wiederherstellung gestartet." -Level SECTION
    Write-UpgradeLog "Instanz      : $SqlInstance" -Level INFO
    Write-UpgradeLog "Backup-Set   : $BackupSetPath" -Level INFO

    #region --- Backup-Set validieren ---
    if (-not (Test-Path $BackupSetPath)) {
        Write-UpgradeLog "Backup-Verzeichnis nicht gefunden: $BackupSetPath" -Level ERROR
        throw "Backup-Verzeichnis '$BackupSetPath' nicht gefunden."
    }

    # Unterverzeichnisse prüfen
    $dirs = @{
        Logins        = Join-Path $BackupSetPath 'Logins'
        LinkedServers = Join-Path $BackupSetPath 'LinkedServers'
        SSISLegacy    = Join-Path $BackupSetPath 'SSIS_Legacy'
        SSISCatalog   = Join-Path $BackupSetPath 'SSIS_Catalog'
        SSRS          = Join-Path $BackupSetPath 'SSRS'
        SSAS          = Join-Path $BackupSetPath 'SSAS'
    }

    $connectParams = @{ SqlInstance = $SqlInstance }
    if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }

    try {
        $server = Connect-DbaInstance @connectParams
        Write-UpgradeLog "Verbunden mit neuer Instanz: $($server.Name) (Version: $($server.VersionString))" -Level INFO
    }
    catch {
        Write-UpgradeLog "Verbindung zur neuen Instanz fehlgeschlagen: $_" -Level ERROR
        throw
    }
    #endregion

    $restoreResults = [ordered]@{}

    #region --- 1. Logins ---
    if (Test-Path $dirs.Logins) {
        $loginFiles = Get-ChildItem $dirs.Logins -Filter '*.sql'
        Write-Host ""
        Write-Host "=== Logins ===" -ForegroundColor Cyan
        Write-Host "Gefunden: $($loginFiles.Count) SQL-Datei(en) in $($dirs.Logins)"

        $doLogins = Invoke-WithConfirmation -Message "Logins wiederherstellen?" -Type YesNo
        if ($doLogins) {
            $loginResult = Restore-SQLLogins -Server $server -BackupDir $dirs.Logins
            $restoreResults['Logins'] = $loginResult
        }
    }
    else {
        Write-UpgradeLog "Kein Login-Backup gefunden - übersprungen." -Level WARN
    }
    #endregion

    #region --- 2. Linked Server ---
    if (Test-Path $dirs.LinkedServers) {
        $lsFile = Join-Path $dirs.LinkedServers 'LinkedServers.sql'
        Write-Host ""
        Write-Host "=== Linked Server ===" -ForegroundColor Cyan

        $doLS = Invoke-WithConfirmation -Message "Linked Server wiederherstellen?" -Type YesNo
        if ($doLS) {
            $lsResult = Restore-SQLScript -Server $server -ScriptFile $lsFile -Label 'LinkedServer'
            $restoreResults['LinkedServers'] = $lsResult

            # Passwort-Warnung
            $lsInv = Join-Path $dirs.LinkedServers 'LinkedServers_Logins_Inventar.csv'
            if (Test-Path $lsInv) {
                $withPwd = Import-Csv $lsInv -Delimiter ';' | Where-Object { $_.HasPassword -eq '1' -and $_.UsesSelfCredentials -eq '0' }
                if ($withPwd.Count -gt 0) {
                    Write-Host ""
                    Write-Host "HINWEIS: $($withPwd.Count) Linked Login(s) benötigen manuelle Passwort-Eingabe:" -ForegroundColor Yellow
                    $withPwd | Select-Object LinkedServerName, RemoteLoginName | Format-Table -AutoSize | Out-Host
                }
            }
        }
    }
    #endregion

    #region --- 3. SSIS Legacy (msdb) ---
    if (Test-Path $dirs.SSISLegacy) {
        $ssisSqlFile = Join-Path $dirs.SSISLegacy 'SSIS_Legacy_Restore.sql'
        Write-Host ""
        Write-Host "=== SSIS Legacy Pakete (msdb) ===" -ForegroundColor Cyan

        $doSSISLeg = Invoke-WithConfirmation -Message "SSIS Legacy-Pakete (msdb) wiederherstellen?" -Type YesNo
        if ($doSSISLeg) {
            $ssisLegResult = Restore-SQLScript -Server $server -ScriptFile $ssisSqlFile -Label 'SSIS_Legacy'
            $restoreResults['SSISLegacy'] = $ssisLegResult
        }
    }
    #endregion

    #region --- 4. SSISDB Catalog ---
    if (Test-Path $dirs.SSISCatalog) {
        $ssisInfo = Get-Content (Join-Path $dirs.SSISCatalog 'SSISDB_Backup_Info.txt') -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "=== SSISDB Catalog ===" -ForegroundColor Cyan

        # Backup-Pfad aus Info-Datei lesen
        $ssisBakPath = $null
        if ($ssisInfo) {
            $bakLine     = $ssisInfo | Where-Object { $_ -match '^Backup-Pfad:' }
            $ssisBakPath = ($bakLine -split ':',2)[1]?.Trim()
        }

        if ($ssisBakPath -and (Test-Path $ssisBakPath)) {
            $doSSISCat = Invoke-WithConfirmation `
                -Message "SSISDB Catalog wiederherstellen aus: $ssisBakPath ?" -Type YesNo
            if ($doSSISCat) {
                $catResult = Restore-SSISDBCatalog -Server $server -BackupPath $ssisBakPath
                $restoreResults['SSISCatalog'] = $catResult
            }
        }
        else {
            Write-UpgradeLog "SSISDB Backup-Datei nicht gefunden: $ssisBakPath - manuell wiederherstellen." -Level WARN
            Write-Host "SSISDB Backup-Pfad: $ssisBakPath" -ForegroundColor Yellow
            Write-Host "Bitte SSISDB manuell wiederherstellen (siehe SSISDB_Backup_Info.txt)." -ForegroundColor Yellow
        }
    }
    #endregion

    #region --- 5. SSRS ---
    if (Test-Path $dirs.SSRS) {
        Write-Host ""
        Write-Host "=== SSRS Inhalte ===" -ForegroundColor Cyan

        $doSSRS = Invoke-WithConfirmation -Message "SSRS Inhalte wiederherstellen?" -Type YesNo
        if ($doSSRS) {
            $ssrsResult = Restore-SSRSContent -Server $server `
                                              -BackupDir $dirs.SSRS `
                                              -ReportServerDB $SSRSReportServerDB
            $restoreResults['SSRS'] = $ssrsResult
        }
    }
    #endregion

    #region --- 6. SSAS ---
    if (Test-Path $dirs.SSAS) {
        Write-Host ""
        Write-Host "=== SSAS Datenbanken ===" -ForegroundColor Cyan

        $ssasInv = Join-Path $dirs.SSAS 'SSAS_Backup_Inventar.csv'
        if (Test-Path $ssasInv) {
            $ssasBackups = Import-Csv $ssasInv -Delimiter ';' | Where-Object { $_.Status -eq 'OK' }
            Write-Host "Gefundene SSAS Backups: $($ssasBackups.Count)"
            $ssasBackups | Select-Object DatabaseName, BackupFile, Mode | Format-Table -AutoSize | Out-Host
        }

        $doSSAS = Invoke-WithConfirmation -Message "SSAS Datenbanken wiederherstellen?" -Type YesNo
        if ($doSSAS) {
            $ssasServer = if ($SSASServer) { $SSASServer } else { ($SqlInstance -split '\\')[0] }
            $ssasResult = Restore-SSASContent -SSASServer $ssasServer -BackupDir $dirs.SSAS
            $restoreResults['SSAS'] = $ssasResult
        }
    }
    #endregion

    #region --- Abschlussbericht ---
    Write-UpgradeLog "=== Wiederherstellung Abschlussbericht ===" -Level SECTION

    foreach ($key in $restoreResults.Keys) {
        $res = $restoreResults[$key]
        Write-UpgradeLog "$key : $($res | ConvertTo-Json -Compress)" -Level INFO
    }

    Write-UpgradeLog "Wiederherstellung abgeschlossen." -Level SUCCESS

    return $restoreResults
    #endregion
}

#region --- Hilfsfunktionen Restore ---

function Restore-SQLScript {
    param(
        $Server,
        [string]$ScriptFile,
        [string]$Label
    )

    if (-not (Test-Path $ScriptFile)) {
        Write-UpgradeLog "[$Label] Skript-Datei nicht gefunden: $ScriptFile" -Level WARN
        return @{ Status = 'SKIPPED'; Reason = 'FILE_NOT_FOUND' }
    }

    Write-UpgradeLog "[$Label] Führe T-SQL Skript aus: $ScriptFile" -Level INFO

    try {
        # Skript in GO-Batches aufteilen
        $sqlContent = Get-Content $ScriptFile -Raw -Encoding UTF8
        $batches    = $sqlContent -split '\r?\nGO\r?\n|\r?\nGO$' |
                      Where-Object { $_.Trim() -ne '' -and -not ($_.Trim() -match '^--') }

        $ok     = 0
        $errors = 0

        foreach ($batch in $batches) {
            if ($batch.Trim() -eq '') { continue }
            try {
                Invoke-DbaQuery -SqlInstance $Server -Query $batch -ErrorAction Stop
                $ok++
            }
            catch {
                $errors++
                Write-UpgradeLog "[$Label] Batch-Fehler: $($_.Exception.Message.Substring(0,[Math]::Min(200,$_.Exception.Message.Length)))" -Level WARN
            }
        }

        Write-UpgradeLog "[$Label] Abgeschlossen: $ok OK, $errors Fehler." -Level $(if($errors -gt 0){'WARN'}else{'SUCCESS'})
        return @{ Status = 'DONE'; OkCount = $ok; ErrorCount = $errors }
    }
    catch {
        Write-UpgradeLog "[$Label] Kritischer Fehler: $_" -Level ERROR
        return @{ Status = 'ERROR'; Error = $_.ToString() }
    }
}

function Restore-SQLLogins {
    param($Server, [string]$BackupDir)

    # dbatools Export-Datei bevorzugen
    $dtaFile    = Join-Path $BackupDir 'Logins_Export.sql'
    $manualFile = Join-Path $BackupDir 'Logins_Manual.sql'

    $targetFile = if (Test-Path $dtaFile) { $dtaFile } else { $manualFile }

    if (-not (Test-Path $targetFile)) {
        Write-UpgradeLog "[Logins] Keine Skript-Datei gefunden in: $BackupDir" -Level WARN
        return @{ Status = 'SKIPPED' }
    }

    Write-UpgradeLog "[Logins] Verwende: $targetFile" -Level INFO
    return Restore-SQLScript -Server $Server -ScriptFile $targetFile -Label 'Logins'
}

function Restore-SSISDBCatalog {
    param($Server, [string]$BackupPath)

    Write-UpgradeLog "[SSISDB] Restore aus: $BackupPath" -Level INFO

    try {
        # Prüfen ob SSISDB bereits existiert
        $ssisdbExists = Invoke-DbaQuery -SqlInstance $Server `
            -Query "SELECT name FROM sys.databases WHERE name = 'SSISDB'" |
            Select-Object -ExpandProperty name

        if ($ssisdbExists) {
            $overwrite = Invoke-WithConfirmation `
                -Message "SSISDB existiert bereits. Überschreiben?" `
                -WarningDetail "Alle bestehenden SSISDB-Inhalte gehen verloren!" `
                -Type YesNo
            if (-not $overwrite) {
                return @{ Status = 'SKIPPED'; Reason = 'USER_CANCEL' }
            }
        }

        $restoreQuery = @"
RESTORE DATABASE [SSISDB]
FROM DISK = N'$BackupPath'
WITH REPLACE, RECOVERY, STATS = 10
"@
        Invoke-DbaQuery -SqlInstance $Server -Query $restoreQuery -QueryTimeout 3600
        Write-UpgradeLog "[SSISDB] Restore abgeschlossen." -Level SUCCESS
        return @{ Status = 'OK' }
    }
    catch {
        Write-UpgradeLog "[SSISDB] Restore fehlgeschlagen: $_" -Level ERROR
        return @{ Status = 'ERROR'; Error = $_.ToString() }
    }
}

function Restore-SSRSContent {
    param($Server, [string]$BackupDir, [string]$ReportServerDB)

    Write-UpgradeLog "[SSRS] Starte Wiederherstellung aus: $BackupDir" -Level INFO

    $contentDir = Join-Path $BackupDir 'Content'
    if (-not (Test-Path $contentDir)) {
        Write-UpgradeLog "[SSRS] Content-Verzeichnis nicht gefunden: $contentDir" -Level WARN
        return @{ Status = 'SKIPPED' }
    }

    $restored = 0
    $failed   = 0

    # Alle exportierten Dateien iterieren und über DB zurückspielen
    $allFiles = Get-ChildItem $contentDir -Recurse -File

    foreach ($file in $allFiles) {
        try {
            # Pfad relativ zu contentDir = SSRS-Katalog-Pfad
            $relativePath = $file.FullName.Substring($contentDir.Length).Replace('\','/').TrimStart('/')
            $catalogPath  = '/' + ($relativePath -replace '\.[^.]+$','')  # Erweiterung entfernen

            $content = [System.IO.File]::ReadAllBytes($file.FullName)
            $hexContent = '0x' + ([BitConverter]::ToString($content) -replace '-','')

            # Type aus Erweiterung ableiten
            $typeCode = switch ($file.Extension.ToLower()) {
                '.rdl'  { 2 }
                '.rds'  { 5 }
                '.rsd'  { 8 }
                '.smdl' { 6 }
                default { 3 }   # Resource
            }

            $upsertQuery = @"
IF NOT EXISTS (SELECT 1 FROM [$ReportServerDB].dbo.Catalog WHERE Path = N'$catalogPath')
BEGIN
    INSERT INTO [$ReportServerDB].dbo.Catalog
        (ItemID, Name, Path, Type, Content, CreatedDate, ModifiedDate, CreatedByID, ModifiedByID, PolicyID)
    SELECT
        NEWID(),
        N'$($file.BaseName)',
        N'$catalogPath',
        $typeCode,
        $hexContent,
        GETDATE(),
        GETDATE(),
        (SELECT TOP 1 UserID FROM [$ReportServerDB].dbo.Users WHERE UserType = 1),
        (SELECT TOP 1 UserID FROM [$ReportServerDB].dbo.Users WHERE UserType = 1),
        (SELECT PolicyID FROM [$ReportServerDB].dbo.Catalog WHERE Path = '/')
END
ELSE
BEGIN
    UPDATE [$ReportServerDB].dbo.Catalog
    SET Content = $hexContent, ModifiedDate = GETDATE()
    WHERE Path = N'$catalogPath'
END
"@
            Invoke-DbaQuery -SqlInstance $Server -Query $upsertQuery -ErrorAction Stop
            $restored++
        }
        catch {
            Write-UpgradeLog "[SSRS] Fehler bei '$($file.Name)': $_" -Level WARN
            $failed++
        }
    }

    # Konfigurationsdateien
    $configDir = Join-Path $BackupDir 'Config'
    if (Test-Path $configDir) {
        Write-Host ""
        Write-Host "SSRS Konfigurationsdateien verfügbar in: $configDir" -ForegroundColor Yellow
        Write-Host "Diese müssen manuell in den SSRS ReportServer-Ordner kopiert werden." -ForegroundColor Yellow
        Write-Host "Standard-Pfad: ${env:ProgramFiles}\Microsoft SQL Server Reporting Services\SSRS\ReportServer\" -ForegroundColor Gray
    }

    Write-UpgradeLog "[SSRS] Abgeschlossen: $restored wiederhergestellt, $failed fehlgeschlagen." -Level $(if($failed -gt 0){'WARN'}else{'SUCCESS'})
    return @{ Status = 'DONE'; Restored = $restored; Failed = $failed }
}

function Restore-SSASContent {
    param([string]$SSASServer, [string]$BackupDir)

    Write-UpgradeLog "[SSAS] Starte Wiederherstellung von: $SSASServer" -Level INFO

    $invFile = Join-Path $BackupDir 'SSAS_Backup_Inventar.csv'
    if (-not (Test-Path $invFile)) {
        Write-UpgradeLog "[SSAS] Inventar-Datei nicht gefunden." -Level WARN
        return @{ Status = 'SKIPPED' }
    }

    $backups  = Import-Csv $invFile -Delimiter ';' | Where-Object { $_.Status -eq 'OK' }
    $restored = 0
    $failed   = 0

    # AMO laden (gleiche Logik wie Backup-SSASContent)
    try { Add-Type -AssemblyName 'Microsoft.AnalysisServices.Core' -ErrorAction Stop }
    catch {
        Write-UpgradeLog "[SSAS] AMO nicht verfügbar - SSAS Restore muss manuell erfolgen." -Level WARN
        Write-Host "SSAS Backup-Dateien verfügbar in: $BackupDir" -ForegroundColor Yellow
        Write-Host "Bitte SSAS Datenbanken manuell über SSMS wiederherstellen." -ForegroundColor Yellow
        return @{ Status = 'MANUAL_REQUIRED' }
    }

    try {
        $ssas = New-Object Microsoft.AnalysisServices.Server
        $ssas.Connect("Data Source=$SSASServer;")
    }
    catch {
        Write-UpgradeLog "[SSAS] Verbindung fehlgeschlagen: $_" -Level ERROR
        return @{ Status = 'ERROR'; Error = $_.ToString() }
    }

    foreach ($backup in $backups) {
        $backupFile = Split-Path $backup.BackupFile -Leaf

        Write-Host "Wiederherstellen: $($backup.DatabaseName) aus $backupFile" -ForegroundColor Cyan
        $doRestore = Invoke-WithConfirmation `
            -Message "SSAS-Datenbank '$($backup.DatabaseName)' wiederherstellen?" -Type YesNo

        if (-not $doRestore) { continue }

        try {
            $ssas.Restore(
                $backupFile,              # Dateiname (relativ zum SSAS BackupDir)
                $backup.DatabaseName,     # Ziel-Datenbankname
                $true                     # AllowOverwrite
            )
            Write-UpgradeLog "[SSAS] '$($backup.DatabaseName)' wiederhergestellt." -Level SUCCESS
            $restored++
        }
        catch {
            Write-UpgradeLog "[SSAS] Fehler bei '$($backup.DatabaseName)': $_" -Level ERROR
            $failed++
        }
    }

    try { $ssas.Disconnect() } catch {}

    return @{ Status = 'DONE'; Restored = $restored; Failed = $failed }
}

#endregion
