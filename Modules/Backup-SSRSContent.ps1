#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert SSRS-Inhalte über direkten Datenbankzugriff.
.DESCRIPTION
    Exportiert aus der ReportServer-Datenbank:
    - Report-Definitionen als .rdl Dateien
    - Freigegebene Datenquellen (.rds)
    - Freigegebene Datasets (.rsd)
    - Ordnerstruktur
    - Subscriptions (als CSV-Inventar, da Passwörter nicht exportierbar)
    - Rollen und Berechtigungen
    Sichert zudem SSRS-Konfigurationsdateien vom Dateisystem.
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-SSRSContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [System.Management.Automation.PSCredential]
        $SqlCredential,

        # Name der ReportServer-Datenbank (Standard: ReportServer)
        [string]$ReportServerDB = 'ReportServer',

        # Pfad zum SSRS-Installationsverzeichnis für Konfigurationsdateien
        [string]$SSRSInstallPath
    )

    Write-UpgradeLog "SSRS Sicherung gestartet für: $SqlInstance (DB: $ReportServerDB)" -Level SECTION

    #region --- Verbindung und DB-Prüfung ---
    try {
        $connectParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }
        $server = Connect-DbaInstance @connectParams

        $dbExists = Invoke-DbaQuery -SqlInstance $server `
            -Query "SELECT name FROM sys.databases WHERE name = '$ReportServerDB'" |
            Select-Object -ExpandProperty name

        if (-not $dbExists) {
            Write-UpgradeLog "Datenbank '$ReportServerDB' nicht gefunden - SSRS Sicherung übersprungen." -Level WARN
            return [PSCustomObject]@{ SSRSExists = $false }
        }
        Write-UpgradeLog "ReportServer-DB '$ReportServerDB' gefunden." -Level INFO
    }
    catch {
        Write-UpgradeLog "Verbindungsfehler: $_" -Level ERROR
        throw
    }
    #endregion

    #region --- Kataloginhalte abfragen ---
    # Alle Objekte aus dem Catalog
    $catalogQuery = @"
SELECT
    c.ItemID,
    c.Name,
    c.Path,
    c.Type,           -- 1=Folder, 2=Report, 3=Resource, 4=LinkedReport, 5=DataSource, 6=Model, 8=SharedDataset
    c.Description,
    c.Hidden,
    c.CreatedDate,
    c.ModifiedDate,
    c.CreatedByID,
    c.ModifiedByID,
    cu.UserName  AS CreatedBy,
    mu.UserName  AS ModifiedBy,
    c.Content,        -- VARBINARY: die eigentliche Definition
    DATALENGTH(c.Content) AS ContentSize
FROM [$ReportServerDB].dbo.Catalog c
LEFT JOIN [$ReportServerDB].dbo.Users cu ON c.CreatedByID  = cu.UserID
LEFT JOIN [$ReportServerDB].dbo.Users mu ON c.ModifiedByID = mu.UserID
WHERE c.Type IN (1,2,3,4,5,6,8)   -- alle relevanten Typen
ORDER BY c.Path
"@

    try {
        $catalogItems = Invoke-DbaQuery -SqlInstance $server -Query $catalogQuery
        Write-UpgradeLog "$($catalogItems.Count) Katalogobjekte gefunden." -Level INFO
    }
    catch {
        Write-UpgradeLog "Fehler beim Abfragen des Catalogs: $_" -Level ERROR
        throw
    }

    $typeMap = @{
        1 = @{ Name = 'Folder';        Ext = $null  }
        2 = @{ Name = 'Report';        Ext = '.rdl' }
        3 = @{ Name = 'Resource';      Ext = ''     }
        4 = @{ Name = 'LinkedReport';  Ext = '.rdl' }
        5 = @{ Name = 'DataSource';    Ext = '.rds' }
        6 = @{ Name = 'Model';         Ext = '.smdl'}
        8 = @{ Name = 'SharedDataset'; Ext = '.rsd' }
    }
    #endregion

    #region --- Dateien exportieren ---
    $contentDir   = Join-Path $OutputPath 'Content'
    $null = New-Item -Path $contentDir -ItemType Directory -Force

    $exported = 0
    $failed   = 0

    foreach ($item in $catalogItems) {
        # Ordner: nur Verzeichnis anlegen
        if ($item.Type -eq 1) {
            $safePath = ($item.Path -replace '[<>:"|?*]','_').TrimStart('/')
            $dir      = Join-Path $contentDir $safePath
            $null     = New-Item -Path $dir -ItemType Directory -Force
            continue
        }

        if (-not $item.Content) { continue }

        try {
            # Pfad ableiten
            $itemDir  = Split-Path $item.Path -Parent
            $safePath = ($itemDir -replace '[<>:"|?*]','_').TrimStart('/')
            $outDir   = Join-Path $contentDir $safePath
            $null     = New-Item -Path $outDir -ItemType Directory -Force

            $ext      = $typeMap[$item.Type].Ext
            if (-not $ext) {
                # Ressource: Dateiname enthält oft schon Erweiterung
                $ext = [System.IO.Path]::GetExtension($item.Name)
            }
            $safeName = ($item.Name -replace '[<>:"|?*\\\/]','_')
            $outFile  = Join-Path $outDir "$safeName$ext"

            # Content als Bytes → XML-String
            if ($item.Content -is [byte[]]) {
                $xmlStr = [System.Text.Encoding]::Unicode.GetString($item.Content)
            }
            else {
                $xmlStr = $item.Content.ToString()
            }
            $xmlStr = $xmlStr.TrimStart([char]0xFEFF)
            $xmlStr | Out-File -FilePath $outFile -Encoding Unicode
            $exported++
        }
        catch {
            Write-UpgradeLog "Fehler beim Export von '$($item.Path)': $_" -Level WARN
            $failed++
        }
    }

    Write-UpgradeLog "Inhalte exportiert: $exported erfolgreich, $failed fehlgeschlagen." -Level INFO
    #endregion

    #region --- Subscriptions Inventar ---
    Write-UpgradeLog "Exportiere Subscriptions Inventar..." -Level INFO

    $subQuery = @"
SELECT
    s.SubscriptionID,
    c.Path          AS ReportPath,
    c.Name          AS ReportName,
    u.UserName      AS Owner,
    s.EventType,
    s.DeliveryExtension,
    s.Description,
    s.LastStatus,
    s.LastRunTime,
    s.ModifiedDate,
    s.Parameters
FROM [$ReportServerDB].dbo.Subscriptions s
JOIN [$ReportServerDB].dbo.Catalog       c ON s.Report_OID = c.ItemID
JOIN [$ReportServerDB].dbo.Users         u ON s.OwnerID    = u.UserID
ORDER BY c.Path
"@

    try {
        $subscriptions = Invoke-DbaQuery -SqlInstance $server -Query $subQuery
        $subCsv = Join-Path $OutputPath 'SSRS_Subscriptions_Inventar.csv'
        $subscriptions | Export-Csv -Path $subCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-UpgradeLog "$($subscriptions.Count) Subscriptions exportiert (Inventar)." -Level INFO
    }
    catch {
        Write-UpgradeLog "Subscriptions konnten nicht abgefragt werden: $_" -Level WARN
    }
    #endregion

    #region --- Rollen und Berechtigungen ---
    Write-UpgradeLog "Exportiere SSRS Rollen und Berechtigungen..." -Level INFO

    $rolesQuery = @"
SELECT
    c.Path,
    u.UserName,
    r.RoleName,
    r.Description AS RoleDescription
FROM [$ReportServerDB].dbo.PolicyUserRole pur
JOIN [$ReportServerDB].dbo.Policies  p ON pur.PolicyID = p.PolicyID
JOIN [$ReportServerDB].dbo.Catalog   c ON p.PolicyID   = c.PolicyID
JOIN [$ReportServerDB].dbo.Users     u ON pur.UserID   = u.UserID
JOIN [$ReportServerDB].dbo.Roles     r ON pur.RoleID   = r.RoleID
ORDER BY c.Path, u.UserName
"@

    try {
        $roles    = Invoke-DbaQuery -SqlInstance $server -Query $rolesQuery
        $rolesCsv = Join-Path $OutputPath 'SSRS_Rollen_Berechtigungen.csv'
        $roles | Export-Csv -Path $rolesCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-UpgradeLog "$($roles.Count) Rollen-Zuordnungen exportiert." -Level INFO
    }
    catch {
        Write-UpgradeLog "Rollen konnten nicht abgefragt werden: $_" -Level WARN
    }
    #endregion

    #region --- Konfigurationsdateien sichern ---
    Write-UpgradeLog "Suche SSRS Konfigurationsdateien..." -Level INFO

    $configFiles = @(
        'rsreportserver.config',
        'rssrvpolicy.config',
        'reportingservicesservice.exe.config',
        'RSWebApplication.config',
        'web.config'
    )

    # Automatische Suche wenn kein Pfad angegeben
    if (-not $SSRSInstallPath) {
        $ssrsPaths = @(
            "${env:ProgramFiles}\Microsoft SQL Server Reporting Services\SSRS\ReportServer",
            "${env:ProgramFiles}\Microsoft SQL Server\MSRS*\Reporting Services\ReportServer",
            "${env:ProgramFiles}\Microsoft SQL Server\MSRS*\Reporting Services\ReportServer"
        )

        foreach ($p in $ssrsPaths) {
            $resolved = Resolve-Path $p -ErrorAction SilentlyContinue
            if ($resolved) {
                $SSRSInstallPath = $resolved.Path | Select-Object -First 1
                Write-UpgradeLog "SSRS Pfad gefunden: $SSRSInstallPath" -Level INFO
                break
            }
        }

        # Alternativ Registry
        if (-not $SSRSInstallPath) {
            $regPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server Reporting Services',
                'HKLM:\SOFTWARE\Microsoft\SQLServerReportingServices'
            )
            foreach ($rp in $regPaths) {
                if (Test-Path $rp) {
                    $installPath = (Get-ItemProperty $rp -ErrorAction SilentlyContinue).InstallDir
                    if ($installPath -and (Test-Path $installPath)) {
                        $SSRSInstallPath = Join-Path $installPath 'ReportServer'
                        Write-UpgradeLog "SSRS Pfad über Registry: $SSRSInstallPath" -Level INFO
                        break
                    }
                }
            }
        }
    }

    $configDir     = Join-Path $OutputPath 'Config'
    $null          = New-Item -Path $configDir -ItemType Directory -Force
    $copiedConfigs = 0

    if ($SSRSInstallPath -and (Test-Path $SSRSInstallPath)) {
        foreach ($cfgFile in $configFiles) {
            $src = Join-Path $SSRSInstallPath $cfgFile
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination $configDir -Force
                Write-UpgradeLog "Konfigurationsdatei gesichert: $cfgFile" -Level INFO
                $copiedConfigs++
            }
        }
    }
    else {
        Write-UpgradeLog "SSRS Installationspfad nicht gefunden - Konfigurationsdateien müssen manuell gesichert werden." -Level WARN
    }
    #endregion

    #region --- Inventar CSV ---
    $invFile = Join-Path $OutputPath 'SSRS_Catalog_Inventar.csv'
    $catalogItems | Select-Object Name, Path, Type, Hidden, CreatedDate, ModifiedDate,
                                  CreatedBy, ModifiedBy, ContentSize |
                    Export-Csv -Path $invFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    #endregion

    Write-UpgradeLog "SSRS Sicherung abgeschlossen." -Level SUCCESS

    return [PSCustomObject]@{
        SSRSExists        = $true
        ExportedItems     = $exported
        FailedItems       = $failed
        SubscriptionCount = $subscriptions.Count
        RoleCount         = $roles.Count
        CopiedConfigs     = $copiedConfigs
        ContentDirectory  = $contentDir
        ConfigDirectory   = $configDir
    }
}
