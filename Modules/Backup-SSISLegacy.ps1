#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert Legacy SSIS-Pakete aus der msdb-Datenbank.
.DESCRIPTION
    Exportiert SSIS-Pakete die in msdb.dbo.sysssispackages gespeichert sind:
    - Als .dtsx Dateien (XML)
    - Als T-SQL INSERT-Skript (für exakte Wiederherstellung inkl. Metadaten)
    Berücksichtigt Ordnerstruktur (sysssispackagefolders)
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-SSISLegacy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [System.Management.Automation.PSCredential]
        $SqlCredential
    )

    Write-UpgradeLog "SSIS Legacy (msdb) Sicherung gestartet für: $SqlInstance" -Level SECTION

    #region --- Verbindung ---
    try {
        $connectParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }
        $server = Connect-DbaInstance @connectParams
        Write-UpgradeLog "Verbunden mit: $($server.Name)" -Level INFO
    }
    catch {
        Write-UpgradeLog "Verbindung fehlgeschlagen: $_" -Level ERROR
        throw
    }
    #endregion

    #region --- Pakete abfragen ---
    $packageQuery = @"
SELECT
    p.id            AS PackageID,
    p.name          AS PackageName,
    p.description   AS Description,
    p.createdate    AS CreateDate,
    p.folderid      AS FolderID,
    f.foldername    AS FolderName,
    p.ownersid      AS OwnerSID,
    p.packageformat AS PackageFormat,
    p.packagetype   AS PackageType,
    p.vermajor      AS VersionMajor,
    p.verminor      AS VersionMinor,
    p.verbuild      AS VersionBuild,
    p.vercomments   AS VersionComments,
    p.isencrypted   AS IsEncrypted,
    p.packagedata   AS PackageData,
    DATALENGTH(p.packagedata) AS PackageSize
FROM msdb.dbo.sysssispackages p
LEFT JOIN msdb.dbo.sysssispackagefolders f ON p.folderid = f.folderid
ORDER BY f.foldername, p.name
"@

    $folderQuery = @"
SELECT
    folderid,
    foldername,
    parentfolderid
FROM msdb.dbo.sysssispackagefolders
ORDER BY foldername
"@

    try {
        $packages = Invoke-DbaQuery -SqlInstance $server -Query $packageQuery
        $folders  = Invoke-DbaQuery -SqlInstance $server -Query $folderQuery
        Write-UpgradeLog "$($packages.Count) SSIS Legacy-Pakete gefunden." -Level INFO
    }
    catch {
        Write-UpgradeLog "Fehler beim Abfragen der SSIS-Pakete (msdb): $_" -Level ERROR
        throw
    }
    #endregion

    if ($packages.Count -eq 0) {
        Write-UpgradeLog "Keine Legacy SSIS-Pakete in msdb vorhanden." -Level INFO
        return [PSCustomObject]@{ PackageCount = 0 }
    }

    #region --- Ordnerstruktur aufbauen ---
    # Hilfsfunktion: rekursiver Pfad für einen Ordner
    function Get-FolderPath {
        param($FolderID, $FolderList)
        if (-not $FolderID) { return '' }
        $folder = $FolderList | Where-Object { $_.folderid -eq $FolderID }
        if (-not $folder)    { return '' }
        $parentPath = Get-FolderPath -FolderID $folder.parentfolderid -FolderList $FolderList
        if ($parentPath) { return "$parentPath\$($folder.foldername)" }
        return $folder.foldername
    }
    #endregion

    #region --- .dtsx Dateien exportieren ---
    $dtxsDir = Join-Path $OutputPath 'DTSX'
    $null = New-Item -Path $dtxsDir -ItemType Directory -Force

    $exportedDtsx = 0
    $failedDtsx   = 0

    foreach ($pkg in $packages) {
        try {
            # Ordnerpfad für Unterverzeichnis-Struktur
            $folderPath = Get-FolderPath -FolderID $pkg.FolderID -FolderList $folders
            $subDir     = if ($folderPath) {
                              Join-Path $dtxsDir ($folderPath -replace '[\\/:*?"<>|]','_')
                          } else {
                              Join-Path $dtxsDir '_Root'
                          }
            $null = New-Item -Path $subDir -ItemType Directory -Force

            # PackageData ist VARBINARY → als XML decodieren
            if ($pkg.PackageData -is [byte[]]) {
                $xmlContent = [System.Text.Encoding]::Unicode.GetString($pkg.PackageData)
            }
            elseif ($pkg.PackageData -is [string]) {
                $xmlContent = $pkg.PackageData
            }
            else {
                Write-UpgradeLog "Unbekanntes Datenformat für Paket '$($pkg.PackageName)'" -Level WARN
                $failedDtsx++
                continue
            }

            # BOM entfernen falls vorhanden
            $xmlContent = $xmlContent.TrimStart([char]0xFEFF)

            # Auf Verschlüsselung prüfen
            if ($pkg.IsEncrypted) {
                Write-UpgradeLog "Paket '$($pkg.PackageName)' ist verschlüsselt - .dtsx wird gespeichert, kann aber ohne Schlüssel nicht gelesen werden." -Level WARN
            }

            $safeName = $pkg.PackageName -replace '[\\/:*?"<>|]', '_'
            $dtxsFile = Join-Path $subDir "$safeName.dtsx"
            $xmlContent | Out-File -FilePath $dtxsFile -Encoding Unicode
            $exportedDtsx++

            Write-UpgradeLog "Exportiert: $(if($folderPath){"$folderPath\"}else{''})\$($pkg.PackageName).dtsx" -Level DEBUG
        }
        catch {
            Write-UpgradeLog "Fehler beim Export von Paket '$($pkg.PackageName)': $_" -Level WARN
            $failedDtsx++
        }
    }

    Write-UpgradeLog "DTSX Export: $exportedDtsx erfolgreich, $failedDtsx fehlgeschlagen." -Level INFO
    #endregion

    #region --- T-SQL INSERT-Skript ---
    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- SSIS Legacy Pakete - msdb Wiederherstellung")
    $null = $sb.AppendLine("-- Instanz  : $SqlInstance")
    $null = $sb.AppendLine("-- Erstellt : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine("-- Pakete   : $($packages.Count)")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("USE [msdb]")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine("")

    # Ordner zuerst anlegen
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- SSIS Ordner anlegen")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("")

    foreach ($folder in ($folders | Sort-Object foldername)) {
        $parentGuid = if ($folder.parentfolderid) {
            "'$($folder.parentfolderid)'"
        } else {
            "NULL"
        }
        $null = $sb.AppendLine(@"
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysssispackagefolders WHERE folderid = '$($folder.folderid)')
BEGIN
    INSERT INTO msdb.dbo.sysssispackagefolders (folderid, foldername, parentfolderid)
    VALUES ('$($folder.folderid)', N'$($folder.foldername)', $parentGuid)
END
GO
"@)
    }

    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- SSIS Pakete wiederherstellen")
    $null = $sb.AppendLine("-- HINWEIS: Bei verschlüsselten Paketen muss der Schlüssel")
    $null = $sb.AppendLine("--          bekannt sein. Alternativ .dtsx Dateien verwenden.")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("")

    foreach ($pkg in $packages) {
        $encNote = if ($pkg.IsEncrypted) { "-- ACHTUNG: Dieses Paket ist verschlüsselt!`n" } else { "" }
        $folderRef = if ($pkg.FolderID) { "'$($pkg.FolderID)'" } else { "NULL" }

        # PackageData als Hex-String für T-SQL
        $hexData = if ($pkg.PackageData -is [byte[]]) {
            '0x' + ([System.BitConverter]::ToString($pkg.PackageData) -replace '-','')
        } else {
            # Als Unicode-Bytes
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($pkg.PackageData.ToString())
            '0x' + ([System.BitConverter]::ToString($bytes) -replace '-','')
        }

        $null = $sb.AppendLine($encNote)
        $null = $sb.AppendLine("-- Paket: $($pkg.PackageName) (Ordner: $(if($pkg.FolderName){$pkg.FolderName}else{'Root'}))")
        $null = $sb.AppendLine(@"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysssispackages WHERE name = N'$($pkg.PackageName)' AND folderid = $folderRef)
BEGIN
    -- Update bestehend
    UPDATE msdb.dbo.sysssispackages
    SET packagedata    = $hexData,
        description    = N'$($pkg.Description -replace "'","''")',
        packageformat  = $($pkg.PackageFormat),
        packagetype    = $($pkg.PackageType),
        vermajor       = $($pkg.VersionMajor),
        verminor       = $($pkg.VersionMinor),
        verbuild       = $($pkg.VersionBuild),
        isencrypted    = $($pkg.IsEncrypted)
    WHERE name = N'$($pkg.PackageName)' AND folderid = $folderRef
END
ELSE
BEGIN
    -- Neu einfügen
    INSERT INTO msdb.dbo.sysssispackages
        (id, name, description, createdate, folderid, ownersid,
         packageformat, packagetype, vermajor, verminor, verbuild,
         vercomments, isencrypted, packagedata)
    VALUES (
        '$($pkg.PackageID)',
        N'$($pkg.PackageName)',
        N'$($pkg.Description -replace "'","''")',
        '$($pkg.CreateDate.ToString("yyyy-MM-dd HH:mm:ss"))',
        $folderRef,
        $($pkg.OwnerSID),
        $($pkg.PackageFormat),
        $($pkg.PackageType),
        $($pkg.VersionMajor),
        $($pkg.VersionMinor),
        $($pkg.VersionBuild),
        N'$($pkg.VersionComments -replace "'","''")',
        $($pkg.IsEncrypted),
        $hexData
    )
END
GO
"@)
    }

    $sqlFile = Join-Path $OutputPath 'SSIS_Legacy_Restore.sql'
    $sb.ToString() | Out-File -FilePath $sqlFile -Encoding UTF8
    Write-UpgradeLog "T-SQL Wiederherstellungsskript gespeichert: $sqlFile" -Level SUCCESS
    #endregion

    #region --- Inventar als CSV ---
    $csvFile = Join-Path $OutputPath 'SSIS_Legacy_Inventar.csv'
    $packages | Select-Object PackageName, FolderName, CreateDate, VersionMajor, VersionMinor,
                               PackageFormat, IsEncrypted, PackageSize |
                Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    #endregion

    $encCount = ($packages | Where-Object { $_.IsEncrypted }).Count
    if ($encCount -gt 0) {
        Write-UpgradeLog "HINWEIS: $encCount verschlüsselte Paket(e) - Schlüssel/Passwort für Wiederherstellung notwendig!" -Level WARN
    }

    Write-UpgradeLog "SSIS Legacy Sicherung abgeschlossen: $($packages.Count) Pakete, $exportedDtsx DTSX-Dateien." -Level SUCCESS

    return [PSCustomObject]@{
        PackageCount    = $packages.Count
        ExportedDtsx    = $exportedDtsx
        FailedDtsx      = $failedDtsx
        EncryptedCount  = $encCount
        SqlFile         = $sqlFile
        DtsxDirectory   = $dtxsDir
        CsvFile         = $csvFile
    }
}
