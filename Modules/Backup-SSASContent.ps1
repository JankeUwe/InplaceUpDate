#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert SSAS-Datenbanken (Multidimensional und Tabular) via XMLA Backup.
.DESCRIPTION
    Erkennt automatisch den SSAS-Modus (Multidimensional/Tabular).
    Führt für jede SSAS-Datenbank ein .abf-Backup durch.
    Exportiert zusätzlich XMLA-Definitionsskripte als Dokumentation.
    
    VORAUSSETZUNG: Microsoft.AnalysisServices.Core Assembly muss verfügbar sein
    (wird mit SQL Server Management Studio oder SSAS selbst installiert).
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-SSASContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,               # SQL Server Instanz (für Verbindungskontext)

        [Parameter(Mandatory)]
        [string]$OutputPath,

        # SSAS Server Name, z.B. 'localhost' oder 'localhost\TABULAR'
        # Falls nicht angegeben: gleicher Server wie SqlInstance
        [string]$SSASServer,

        # Lokaler Pfad auf dem SSAS-Server für .abf Backup-Dateien
        [string]$BackupPath,

        [System.Management.Automation.PSCredential]
        $Credential
    )

    Write-UpgradeLog "SSAS Sicherung gestartet." -Level SECTION

    # SSAS-Server ableiten
    if (-not $SSASServer) {
        $SSASServer = ($SqlInstance -split '\\')[0]  # Nur Hostname, keine SQL-Instanz
    }

    #region --- AMO Assembly laden ---
    $amoLoaded = $false
    $amoAssemblies = @(
        # SSAS 2019/2022
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 19\Common7\IDE\CommonExtensions\Microsoft\SSAS\Microsoft.AnalysisServices.Core.dll",
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 18\Common7\IDE\CommonExtensions\Microsoft\SSAS\Microsoft.AnalysisServices.Core.dll",
        # Direkt aus SSAS
        "${env:ProgramFiles}\Microsoft SQL Server\MSAS*\OLAP\bin\Microsoft.AnalysisServices.Core.dll",
        # NuGet-Pfad falls installiert
        "$env:USERPROFILE\.nuget\packages\microsoft.analysisservices.adomdclient.*\lib\net*\Microsoft.AnalysisServices.AdomdClient.dll"
    )

    foreach ($asmPath in $amoAssemblies) {
        $resolved = Resolve-Path $asmPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved -and (Test-Path $resolved.Path)) {
            try {
                Add-Type -Path $resolved.Path -ErrorAction Stop
                $amoLoaded = $true
                Write-UpgradeLog "AMO Assembly geladen: $($resolved.Path)" -Level INFO
                break
            }
            catch {
                # weiter versuchen
            }
        }
    }

    # Fallback: AMO über GAC
    if (-not $amoLoaded) {
        try {
            Add-Type -AssemblyName 'Microsoft.AnalysisServices.Core' -ErrorAction Stop
            $amoLoaded = $true
            Write-UpgradeLog "AMO Assembly über GAC geladen." -Level INFO
        }
        catch {
            Write-UpgradeLog "AMO Assembly nicht gefunden - SSAS Backup via XMLA nicht möglich." -Level WARN
        }
    }
    #endregion

    #region --- SSAS Verbindung ---
    if (-not $amoLoaded) {
        Write-UpgradeLog "SSAS Sicherung übersprungen (AMO nicht verfügbar)." -Level WARN
        return [PSCustomObject]@{ SSASAvailable = $false; Reason = 'AMO_NOT_FOUND' }
    }

    try {
        $connStr = "Data Source=$SSASServer;"
        if ($Credential) {
            $connStr += "User ID=$($Credential.UserName);Password=$($Credential.GetNetworkCredential().Password);"
        }

        $ssasServer = New-Object Microsoft.AnalysisServices.Server
        $ssasServer.Connect($connStr)

        if (-not $ssasServer.Connected) {
            Write-UpgradeLog "SSAS Verbindung zu '$SSASServer' konnte nicht hergestellt werden." -Level WARN
            return [PSCustomObject]@{ SSASAvailable = $false; Reason = 'CONNECTION_FAILED' }
        }

        $ssasMode = $ssasServer.ServerMode
        Write-UpgradeLog "SSAS verbunden: $SSASServer (Modus: $ssasMode)" -Level INFO
    }
    catch {
        Write-UpgradeLog "SSAS Verbindungsfehler: $_" -Level WARN
        return [PSCustomObject]@{ SSASAvailable = $false; Reason = "ERROR: $_" }
    }
    #endregion

    #region --- Backup-Verzeichnis auf SSAS-Server ---
    if (-not $BackupPath) {
        # Standard-Backup-Verzeichnis des SSAS-Servers
        try {
            $BackupPath = $ssasServer.BackupDir
            if (-not $BackupPath) {
                $BackupPath = Join-Path $env:TEMP 'SSAS_Backup'
            }
        }
        catch {
            $BackupPath = $ssasServer.BackupDir
        }
    }

    # Timestamp für Backup-Dateinamen
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    Write-UpgradeLog "SSAS Backup-Verzeichnis: $BackupPath" -Level INFO
    #endregion

    #region --- Alle SSAS-Datenbanken sichern ---
    $databases    = $ssasServer.Databases
    $backedUp     = 0
    $failedDBs    = 0
    $backupFiles  = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-UpgradeLog "$($databases.Count) SSAS-Datenbank(en) gefunden." -Level INFO

    foreach ($db in $databases) {
        Write-UpgradeLog "Sichere SSAS-Datenbank: $($db.Name) (Compatibiltiy: $($db.CompatibilityLevel))" -Level INFO

        $safeName   = $db.Name -replace '[\\/:*?"<>|]', '_'
        $backupFile = "$safeName`_$timestamp.abf"
        $fullBackupPath = Join-Path $BackupPath $backupFile

        try {
            # Backup über AMO
            $db.Backup(
                $backupFile,    # Dateiname (relativ zum SSAS BackupDir)
                $true,          # AllowOverwrite
                $false          # BackupRemotePartitions
            )

            Write-UpgradeLog "Backup erfolgreich: $backupFile" -Level SUCCESS
            $backedUp++

            $backupFiles.Add([PSCustomObject]@{
                DatabaseName = $db.Name
                BackupFile   = $fullBackupPath
                Mode         = $ssasMode
                Compatibility= $db.CompatibilityLevel
                Status       = 'OK'
            })
        }
        catch {
            Write-UpgradeLog "Backup fehlgeschlagen für '$($db.Name)': $_" -Level ERROR
            $failedDBs++

            $backupFiles.Add([PSCustomObject]@{
                DatabaseName = $db.Name
                BackupFile   = $null
                Mode         = $ssasMode
                Compatibility= $db.CompatibilityLevel
                Status       = "FEHLER: $_"
            })
        }

        #region --- XMLA Definition exportieren ---
        try {
            $xmlaFile = Join-Path $OutputPath "$safeName`_Definition.xmla"

            # Scripter für XMLA-Output
            $scripter = New-Object Microsoft.AnalysisServices.Scripter
            $xmlaXml  = New-Object System.Xml.XmlWriter+Settings
            $xmlaXml.Indent = $true
            $xmlaXml.Encoding = [System.Text.Encoding]::UTF8

            $ms        = New-Object System.IO.MemoryStream
            $xmlWriter = [System.Xml.XmlWriter]::Create($ms, $xmlaXml)

            $scripter.ScriptCreate(
                [Microsoft.AnalysisServices.MajorObject[]]@($db),
                $xmlWriter,
                $false
            )
            $xmlWriter.Flush()

            $xmlContent = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $xmlContent | Out-File -FilePath $xmlaFile -Encoding UTF8
            Write-UpgradeLog "XMLA Definition gespeichert: $xmlaFile" -Level INFO
        }
        catch {
            Write-UpgradeLog "XMLA Export fehlgeschlagen für '$($db.Name)': $_" -Level WARN
        }
        #endregion
    }
    #endregion

    #region --- Verbindung trennen ---
    try { $ssasServer.Disconnect() } catch {}
    #endregion

    #region --- Inventar und Backup-Info speichern ---
    $invCsv = Join-Path $OutputPath 'SSAS_Backup_Inventar.csv'
    $backupFiles | Export-Csv -Path $invCsv -NoTypeInformation -Encoding UTF8 -Delimiter ';'

    $infoFile = Join-Path $OutputPath 'SSAS_Backup_Info.txt'
    @"
SSAS Backup Information
=======================
Server     : $SSASServer
Modus      : $ssasMode
Erstellt   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Backup-Dir : $BackupPath
Datenbanken: $($databases.Count) gesamt, $backedUp gesichert, $failedDBs fehlgeschlagen

Wiederherstellung (.abf):
-------------------------
1. SSAS Dienst auf neuem Server starten
2. Backup-Datei in SSAS BackupDir kopieren
3. SSMS öffnen, SSAS verbinden
4. Rechtsklick auf 'Databases' → 'Restore...'
   Oder via XMLA:
   <Restore xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
     <File>DATEINAME.abf</File>
     <DatabaseName>DATENBANKNAME</DatabaseName>
     <AllowOverwrite>true</AllowOverwrite>
   </Restore>

HINWEIS: Backup-Passwort falls verwendet muss bekannt sein!
"@ | Out-File -FilePath $infoFile -Encoding UTF8
    #endregion

    Write-UpgradeLog "SSAS Sicherung abgeschlossen: $backedUp von $($databases.Count) Datenbanken gesichert." -Level SUCCESS

    return [PSCustomObject]@{
        SSASAvailable  = $true
        ServerMode     = $ssasMode
        DatabaseCount  = $databases.Count
        BackedUpCount  = $backedUp
        FailedCount    = $failedDBs
        BackupPath     = $BackupPath
        BackupFiles    = $backupFiles
        InfoFile       = $infoFile
    }
}
