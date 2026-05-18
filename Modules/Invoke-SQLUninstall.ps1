#Requires -Version 5.1
<#
.SYNOPSIS
    Deinstalliert SQL Server und räumt verbleibende Komponenten auf.
.DESCRIPTION
    Führt folgende Schritte durch (jeweils mit Benutzerbestätigung):
    1. SQL Server Setup /ACTION=Uninstall für alle gewählten Komponenten
    2. Aufräumen verbleibender Verzeichnisse
    3. Aufräumen von Registry-Einträgen
    4. Optional: Neustart

    VORAUSSETZUNG: Das Sicherungs-Skript muss erfolgreich abgeschlossen sein.
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Invoke-SQLUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstanceName,          # z.B. 'MSSQLSERVER' oder 'INST01'

        # Pfad zu setup.exe - falls leer: wird gesucht
        [string]$SetupPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,            # Log-Verzeichnis

        # Welche Features deinstalliert werden sollen
        # Leer = alle gefundenen Features
        [string[]]$Features,

        [switch]$SkipCleanup,           # Nur Deinstallation, kein Verzeichnis-Cleanup
        [switch]$NoRestart              # Kein Neustart am Ende
    )

    Write-UpgradeLog "SQL Server Deinstallation gestartet für Instanz: $InstanceName" -Level SECTION

    #region --- Installierte Features ermitteln ---
    Write-UpgradeLog "Ermittle installierte SQL Server Features..." -Level INFO

    $installedFeatures = Get-InstalledSQLFeatures -InstanceName $InstanceName
    if (-not $installedFeatures) {
        Write-UpgradeLog "Keine SQL Server Features für Instanz '$InstanceName' gefunden." -Level WARN
        return
    }

    Write-UpgradeLog "Gefundene Features: $($installedFeatures -join ', ')" -Level INFO

    # Falls keine Features explizit angegeben: alle deinstallieren
    if (-not $Features) {
        $Features = $installedFeatures
    }
    #endregion

    #region --- setup.exe suchen ---
    if (-not $SetupPath -or -not (Test-Path $SetupPath)) {
        Write-UpgradeLog "Suche SQL Server Setup (setup.exe)..." -Level INFO
        $SetupPath = Find-SQLSetup -InstanceName $InstanceName

        if (-not $SetupPath) {
            Write-Host ""
            Write-Host "setup.exe wurde nicht automatisch gefunden." -ForegroundColor Yellow
            Write-Host "Bitte Pfad zu setup.exe eingeben: " -NoNewline
            $SetupPath = (Read-Host).Trim().Trim('"')
        }
    }

    if (-not (Test-Path $SetupPath)) {
        Write-UpgradeLog "setup.exe nicht gefunden: $SetupPath" -Level ERROR
        throw "SQL Server setup.exe nicht gefunden."
    }

    Write-UpgradeLog "setup.exe gefunden: $SetupPath" -Level INFO
    #endregion

    #region --- Installationsverzeichnisse ermitteln ---
    $installDirs = Get-SQLInstallDirectories -InstanceName $InstanceName
    #endregion

    #region --- Bestätigung einholen ---
    Write-Host ""
    Write-Host "Folgende Aktion wird durchgeführt:" -ForegroundColor Cyan
    Write-Host "  Instanz    : $InstanceName"        -ForegroundColor White
    Write-Host "  Features   : $($Features -join ', ')" -ForegroundColor White
    Write-Host "  Setup      : $SetupPath"           -ForegroundColor White
    Write-Host ""

    $confirmed = Invoke-WithConfirmation `
        -Message "SQL Server '$InstanceName' mit den genannten Features DEINSTALLIEREN?" `
        -WarningDetail "Diese Aktion ist NICHT rückgängig zu machen! Sicherung muss abgeschlossen sein." `
        -Type YesNo

    if (-not $confirmed) {
        Write-UpgradeLog "Deinstallation abgebrochen durch Benutzer." -Level WARN
        return
    }
    #endregion

    #region --- Dienste stoppen ---
    Write-UpgradeLog "Stoppe SQL Server Dienste..." -Level INFO

    $serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
    $agentName   = if ($InstanceName -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { "SQLAgent`$$InstanceName" }
    $ssasName    = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLServerOLAPService' } else { "MSOLAP`$$InstanceName" }
    $ssrsName    = 'SQLServerReportingServices'  # SSRS 2017+ ist immer benannte Instanz-unabhängig

    foreach ($svc in @($agentName, $ssasName, $ssrsName, $serviceName)) {
        try {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Write-UpgradeLog "Dienst gestoppt: $svc" -Level INFO
            }
        }
        catch {
            Write-UpgradeLog "Dienst '$svc' konnte nicht gestoppt werden: $_" -Level WARN
        }
    }
    #endregion

    #region --- Setup /ACTION=Uninstall ---
    Write-UpgradeLog "Starte SQL Server Setup Deinstallation..." -Level INFO

    $featureList = $Features -join ','
    $logPath     = Join-Path $OutputPath 'Setup_Uninstall.log'

    $setupArgs = @(
        '/ACTION=Uninstall',
        "/INSTANCENAME=$InstanceName",
        "/FEATURES=$featureList",
        '/QUIET',
        '/NPENABLED=0',
        "/INDICATEPROGRESS"
    )

    Write-UpgradeLog "Setup-Befehl: $SetupPath $($setupArgs -join ' ')" -Level DEBUG

    try {
        $proc = Start-Process -FilePath $SetupPath `
                              -ArgumentList $setupArgs `
                              -Wait `
                              -PassThru `
                              -RedirectStandardOutput $logPath

        if ($proc.ExitCode -eq 0) {
            Write-UpgradeLog "SQL Server Setup Deinstallation abgeschlossen (ExitCode: 0)." -Level SUCCESS
        }
        elseif ($proc.ExitCode -eq 3010) {
            Write-UpgradeLog "Deinstallation abgeschlossen - Neustart erforderlich (ExitCode: 3010)." -Level WARN
        }
        else {
            Write-UpgradeLog "Setup beendet mit ExitCode: $($proc.ExitCode) - bitte Setup-Log prüfen: $logPath" -Level WARN
        }
    }
    catch {
        Write-UpgradeLog "Setup-Prozess Fehler: $_" -Level ERROR
        throw
    }
    #endregion

    #region --- Verzeichnis-Cleanup ---
    if (-not $SkipCleanup) {
        $cleanupConfirmed = Invoke-WithConfirmation `
            -Message "Verbleibende SQL Server Verzeichnisse aufräumen?" `
            -WarningDetail "Entfernt Verzeichnisse die das Setup nicht vollständig bereinigt hat." `
            -Type YesNo

        if ($cleanupConfirmed) {
            Invoke-SQLDirectoryCleanup -InstallDirs $installDirs -InstanceName $InstanceName
        }
    }
    #endregion

    #region --- Registry-Cleanup ---
    $regConfirmed = Invoke-WithConfirmation `
        -Message "Registry-Einträge für '$InstanceName' bereinigen?" `
        -WarningDetail "Entfernt verbleibende Registry-Keys der deinstallierten Instanz." `
        -Type YesNo

    if ($regConfirmed) {
        Invoke-SQLRegistryCleanup -InstanceName $InstanceName
    }
    #endregion

    #region --- Neustart ---
    if (-not $NoRestart) {
        $restartConfirmed = Invoke-WithConfirmation `
            -Message "Server jetzt neu starten?" `
            -WarningDetail "Empfohlen nach SQL Server Deinstallation um alle Komponenten vollständig zu entfernen." `
            -Type YesNo

        if ($restartConfirmed) {
            Write-UpgradeLog "Server wird in 30 Sekunden neu gestartet..." -Level WARN
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        }
    }
    #endregion

    Write-UpgradeLog "SQL Server Deinstallation abgeschlossen." -Level SUCCESS
}

#region --- Hilfsfunktionen ---

function Get-InstalledSQLFeatures {
    param([string]$InstanceName)

    $features = [System.Collections.Generic.List[string]]::new()

    # Registry: installierte Komponenten
    $regBase  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    $instKey  = "$regBase\Instance Names\SQL"

    if (-not (Test-Path $instKey)) { return $null }

    $instProps  = Get-ItemProperty $instKey -ErrorAction SilentlyContinue
    $instRegKey = $instProps.$InstanceName

    if (-not $instRegKey) { return $null }

    $featureKey = "$regBase\$instRegKey\ConfigurationState"
    if (Test-Path $featureKey) {
        $fProps = Get-ItemProperty $featureKey -ErrorAction SilentlyContinue
        foreach ($prop in $fProps.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -eq 1 }) {
            $mappedFeature = switch -Wildcard ($prop.Name) {
                'SQL_Engine*'          { 'SQLENGINE' }
                'SQL_Replication*'     { 'REPLICATION' }
                'SQL_FullText*'        { 'FULLTEXT' }
                'SQL_DQ*'              { 'DQ' }
                'AS_*'                 { 'AS' }
                'RS_*'                 { 'RS' }
                'IS_*'                 { 'IS' }
                'MDS_*'                { 'MDS' }
                'SQL_SNAC*'            { 'CONN' }
                'SDK*'                 { 'SDK' }
                'Tools_*'              { 'SSMS' }
                default                { $null }
            }
            if ($mappedFeature -and $features -notcontains $mappedFeature) {
                $features.Add($mappedFeature)
            }
        }
    }

    # Fallback: Standard-Features annehmen
    if ($features.Count -eq 0) {
        $features.AddRange([string[]]@('SQLENGINE','REPLICATION','FULLTEXT','CONN'))
    }

    return $features
}

function Find-SQLSetup {
    param([string]$InstanceName)

    # Aus Registry: Installationsmedium-Pfad
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\*\Bootstrap\*",
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\*\Setup"
    )

    foreach ($rp in $regPaths) {
        $keys = Get-Item $rp -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $setupDir = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).SQLPath
            if ($setupDir) {
                $setup = Join-Path $setupDir 'setup.exe'
                if (Test-Path $setup) { return $setup }
            }
        }
    }

    # Häufige Pfade prüfen
    $commonPaths = @(
        "${env:ProgramFiles}\Microsoft SQL Server\*\Setup Bootstrap\SQLServer*\setup.exe",
        "D:\setup.exe",
        "E:\setup.exe"
    )

    foreach ($p in $commonPaths) {
        $r = Resolve-Path $p -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($r -and (Test-Path $r.Path)) { return $r.Path }
    }

    return $null
}

function Get-SQLInstallDirectories {
    param([string]$InstanceName)

    $dirs = [System.Collections.Generic.List[string]]::new()

    $regBase = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    $instKey = "$regBase\Instance Names\SQL"

    try {
        $instProps  = Get-ItemProperty $instKey -ErrorAction SilentlyContinue
        $instRegKey = $instProps.$InstanceName

        if ($instRegKey) {
            $setupKey = "$regBase\$instRegKey\Setup"
            if (Test-Path $setupKey) {
                $setupProps = Get-ItemProperty $setupKey -ErrorAction SilentlyContinue
                foreach ($prop in @('SQLDataRoot','SQLBinRoot','SQLPath','SqlClusterInstallDir')) {
                    if ($setupProps.$prop -and (Test-Path $setupProps.$prop)) {
                        $dirs.Add($setupProps.$prop)
                    }
                }
            }
        }
    }
    catch {}

    # Standard-Pfade ergänzen
    $standardPaths = @(
        "${env:ProgramFiles}\Microsoft SQL Server\MSSQL*.$InstanceName",
        "${env:ProgramFiles}\Microsoft SQL Server\MSAS*.$InstanceName",
        "${env:ProgramFiles}\Microsoft SQL Server\MSRS*.$InstanceName"
    )

    foreach ($sp in $standardPaths) {
        $resolved = Resolve-Path $sp -ErrorAction SilentlyContinue
        foreach ($r in $resolved) {
            if ($r -and -not ($dirs -contains $r.Path)) {
                $dirs.Add($r.Path)
            }
        }
    }

    return $dirs
}

function Invoke-SQLDirectoryCleanup {
    param(
        [string[]]$InstallDirs,
        [string]$InstanceName
    )

    Write-UpgradeLog "Starte Verzeichnis-Cleanup..." -Level INFO

    foreach ($dir in $InstallDirs) {
        if (-not (Test-Path $dir)) { continue }

        try {
            Write-UpgradeLog "Entferne Verzeichnis: $dir" -Level INFO
            Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
            Write-UpgradeLog "Verzeichnis entfernt: $dir" -Level SUCCESS
        }
        catch {
            Write-UpgradeLog "Verzeichnis konnte nicht vollständig entfernt werden: $dir - $_" -Level WARN

            # Dateien auflisten die nicht entfernt werden konnten
            $remaining = Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue
            Write-UpgradeLog "Verbleibende Dateien: $($remaining.Count) - bitte manuell prüfen." -Level WARN
        }
    }

    # Shared-Komponenten nur entfernen wenn keine anderen SQL Instanzen vorhanden
    $otherInstances = @()
    $instKey        = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    if (Test-Path $instKey) {
        $props = Get-ItemProperty $instKey -ErrorAction SilentlyContinue
        $otherInstances = $props.PSObject.Properties |
                          Where-Object { $_.Name -notlike 'PS*' -and $_.Name -ne $InstanceName } |
                          Select-Object -ExpandProperty Name
    }

    if ($otherInstances.Count -eq 0) {
        Write-UpgradeLog "Keine weiteren SQL Instanzen - prüfe Shared-Verzeichnisse..." -Level INFO

        $sharedPaths = @(
            "${env:ProgramFiles}\Microsoft SQL Server\*\Shared",
            "${env:ProgramFiles}\Microsoft SQL Server\Client SDK"
        )

        foreach ($sp in $sharedPaths) {
            $resolved = Resolve-Path $sp -ErrorAction SilentlyContinue
            foreach ($r in $resolved) {
                $removeShared = Invoke-WithConfirmation `
                    -Message "Shared-Verzeichnis entfernen: $($r.Path)?" `
                    -WarningDetail "Nur entfernen wenn KEINE anderen SQL-abhängigen Programme vorhanden!" `
                    -Type YesNo
                if ($removeShared) {
                    Remove-Item -Path $r.Path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        Write-UpgradeLog "Weitere SQL Instanzen vorhanden ($($otherInstances -join ', ')) - Shared-Verzeichnisse werden NICHT entfernt." -Level INFO
    }
}

function Invoke-SQLRegistryCleanup {
    param([string]$InstanceName)

    Write-UpgradeLog "Starte Registry-Cleanup für '$InstanceName'..." -Level INFO

    $regBase    = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    $instKey    = "$regBase\Instance Names\SQL"

    try {
        $instProps  = Get-ItemProperty $instKey -ErrorAction SilentlyContinue
        $instRegKey = $instProps.$InstanceName

        if ($instRegKey) {
            $instPath = "$regBase\$instRegKey"
            if (Test-Path $instPath) {
                Remove-Item -Path $instPath -Recurse -Force
                Write-UpgradeLog "Registry-Key entfernt: $instPath" -Level SUCCESS
            }

            # Instance Names Eintrag entfernen
            Remove-ItemProperty -Path $instKey -Name $InstanceName -ErrorAction SilentlyContinue
            Write-UpgradeLog "Instance Names Eintrag entfernt: $InstanceName" -Level SUCCESS
        }
    }
    catch {
        Write-UpgradeLog "Registry-Cleanup Fehler: $_" -Level WARN
    }
}

#endregion
