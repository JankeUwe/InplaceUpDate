#Requires -Version 5.1
<#
.SYNOPSIS
    Prüft Abhängigkeiten einer SQL Server Instanz vor der Deinstallation.
.DESCRIPTION
    Prüft:
    - ODBC Datenquellen (System und User DSN)
    - OLE DB Provider
    - Installierte Visual Studio / SSDT Versionen
    - Weitere SQL Server Instanzen auf dem System
    - Windows-Dienste mit Abhängigkeit auf SQL Server
    - Registrierte SQL Server Client-Bibliotheken
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Test-SQLDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstanceName,          # z.B. 'MSSQLSERVER' oder 'INST01'

        [Parameter(Mandatory)]
        [string]$OutputPath,            # Pfad zum Dependencies-Unterverzeichnis

        [switch]$WarnOnly               # Nur warnen, nicht abbrechen
    )

    Write-UpgradeLog "Abhängigkeitsprüfung gestartet für Instanz: $InstanceName" -Level SECTION

    $issues   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $warnings = [System.Collections.Generic.List[PSCustomObject]]::new()

    #region --- ODBC DSN Prüfung ---
    Write-UpgradeLog "Prüfe ODBC Datenquellen..." -Level INFO

    $odbcPaths = @(
        # System DSN 64-bit
        'HKLM:\SOFTWARE\ODBC\ODBC.INI',
        # System DSN 32-bit (WOW6432Node)
        'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI',
        # User DSN (aktueller Benutzer)
        'HKCU:\SOFTWARE\ODBC\ODBC.INI'
    )

    foreach ($odbcPath in $odbcPaths) {
        if (-not (Test-Path $odbcPath)) { continue }

        $scope = switch -Wildcard ($odbcPath) {
            '*WOW6432*' { 'System-DSN (32-Bit)' }
            'HKLM:*'    { 'System-DSN (64-Bit)' }
            'HKCU:*'    { 'User-DSN'             }
        }

        try {
            $dsns = Get-ChildItem $odbcPath -ErrorAction SilentlyContinue
            foreach ($dsn in $dsns) {
                $props = Get-ItemProperty $dsn.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { continue }

                $driver = $props.Driver
                $server = $props.Server

                # SQL Server spezifische Treiber
                $isSQLDriver = $driver -match 'SQL Server|SQLNCLI|MSOLEDBSQL|ODBC Driver.*SQL'

                if ($isSQLDriver -and $server) {
                    # Prüfen ob der Server auf unsere Instanz zeigt
                    $localAliases = @('localhost','127.0.0.1','(local)','.', $env:COMPUTERNAME)
                    $isLocal = $false
                    foreach ($alias in $localAliases) {
                        if ($server -like "$alias*") { $isLocal = $true; break }
                    }

                    if ($isLocal) {
                        $issues.Add([PSCustomObject]@{
                            Typ      = 'ODBC-DSN'
                            Scope    = $scope
                            Name     = $dsn.PSChildName
                            Detail   = "Server: $server | Treiber: $driver"
                            Schwere  = 'HOCH'
                        })
                        Write-UpgradeLog "ODBC-Abhängigkeit gefunden [$scope]: $($dsn.PSChildName) -> $server" -Level WARN
                    }
                }
            }
        }
        catch {
            Write-UpgradeLog "Fehler beim Lesen von ODBC-Einträgen ($odbcPath): $_" -Level WARN
        }
    }
    #endregion

    #region --- OLE DB Provider Prüfung ---
    Write-UpgradeLog "Prüfe OLE DB Provider..." -Level INFO

    $oledbPaths = @(
        'HKLM:\SOFTWARE\Classes\CLSID',
        'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID'
    )

    $sqlOleDbProviders = @(
        'SQLNCLI',
        'SQLNCLI10',
        'SQLNCLI11',
        'MSOLEDBSQL',
        'MSOLEDBSQL19',
        'SQLOLEDB'
    )

    $foundProviders = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($providerName in $sqlOleDbProviders) {
        $regPath64 = "HKLM:\SOFTWARE\Classes\$providerName"
        $regPath32 = "HKLM:\SOFTWARE\WOW6432Node\Classes\$providerName"

        foreach ($path in @($regPath64, $regPath32)) {
            if (Test-Path $path) {
                $arch = if ($path -match 'WOW6432') { '32-Bit' } else { '64-Bit' }
                try {
                    $ver = (Get-ItemProperty "$path\CurVer" -ErrorAction SilentlyContinue).'(default)'
                    $foundProviders.Add([PSCustomObject]@{
                        Typ     = 'OLE DB Provider'
                        Scope   = $arch
                        Name    = $providerName
                        Detail  = "Version: $ver"
                        Schwere = 'MITTEL'
                    })
                    Write-UpgradeLog "OLE DB Provider gefunden [$arch]: $providerName (Version: $ver)" -Level INFO
                }
                catch {
                    $foundProviders.Add([PSCustomObject]@{
                        Typ     = 'OLE DB Provider'
                        Scope   = $arch
                        Name    = $providerName
                        Detail  = 'Version nicht ermittelbar'
                        Schwere = 'MITTEL'
                    })
                }
            }
        }
    }

    # OLE DB Provider als Warnung (nicht zwingend blockierend)
    foreach ($p in $foundProviders) { $warnings.Add($p) }
    #endregion

    #region --- Visual Studio / SSDT Prüfung ---
    Write-UpgradeLog "Prüfe Visual Studio / SSDT Installation..." -Level INFO

    $vsPaths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio',
        'HKLM:\SOFTWARE\Microsoft\Visual Studio',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Visual Studio'
    )

    foreach ($vsPath in $vsPaths) {
        if (-not (Test-Path $vsPath)) { continue }
        try {
            $vsVersions = Get-ChildItem $vsPath -ErrorAction SilentlyContinue |
                          Where-Object { $_.PSChildName -match '^\d+\.\d+$' }

            foreach ($vsVer in $vsVersions) {
                $installDir = (Get-ItemProperty $vsVer.PSPath -ErrorAction SilentlyContinue).InstallDir
                if (-not $installDir) { continue }

                # SSDT-Prüfung: suche nach SQL Server Data Tools
                $ssdtMarker = Join-Path (Split-Path $installDir -Parent) 'Common7\IDE\Extensions\Microsoft\SQLDB'
                $hasSSDT    = Test-Path $ssdtMarker

                $warnings.Add([PSCustomObject]@{
                    Typ     = 'Visual Studio'
                    Scope   = $vsVer.PSChildName
                    Name    = "Visual Studio $($vsVer.PSChildName)"
                    Detail  = "InstallDir: $installDir | SSDT: $(if($hasSSDT){'Ja'}else{'Nein'})"
                    Schwere = if ($hasSSDT) { 'MITTEL' } else { 'NIEDRIG' }
                })

                Write-UpgradeLog "Visual Studio $($vsVer.PSChildName) gefunden (SSDT: $hasSSDT)" -Level INFO
            }
        }
        catch {
            Write-UpgradeLog "Fehler beim Prüfen von VS-Pfad $vsPath : $_" -Level WARN
        }
    }

    # Neuere VS-Versionen (2017+) über vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        try {
            $vsInstances = & $vswhere -format json -all 2>$null | ConvertFrom-Json
            foreach ($inst in $vsInstances) {
                $warnings.Add([PSCustomObject]@{
                    Typ     = 'Visual Studio (Modern)'
                    Scope   = $inst.installationVersion
                    Name    = $inst.displayName
                    Detail  = "Pfad: $($inst.installationPath)"
                    Schwere = 'NIEDRIG'
                })
                Write-UpgradeLog "Visual Studio (Modern) gefunden: $($inst.displayName) $($inst.installationVersion)" -Level INFO
            }
        }
        catch {
            Write-UpgradeLog "vswhere Aufruf fehlgeschlagen: $_" -Level WARN
        }
    }
    #endregion

    #region --- Weitere SQL Server Instanzen ---
    Write-UpgradeLog "Prüfe weitere SQL Server Instanzen auf diesem Server..." -Level INFO

    $sqlInstReg = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path $sqlInstReg) {
        try {
            $allInstances = Get-ItemProperty $sqlInstReg
            foreach ($prop in ($allInstances.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
                if ($prop.Name -ne $InstanceName) {
                    $warnings.Add([PSCustomObject]@{
                        Typ     = 'SQL Server Instanz'
                        Scope   = 'Lokal'
                        Name    = $prop.Name
                        Detail  = "Registry-Key: $($prop.Value)"
                        Schwere = 'INFO'
                    })
                    Write-UpgradeLog "Weitere SQL Instanz gefunden: $($prop.Name)" -Level INFO
                }
            }
        }
        catch {
            Write-UpgradeLog "Fehler beim Lesen der SQL Instanzen: $_" -Level WARN
        }
    }
    #endregion

    #region --- Windows-Dienste mit SQL Abhängigkeit ---
    Write-UpgradeLog "Prüfe Windows-Dienste mit SQL Server Abhängigkeit..." -Level INFO

    $sqlServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }

    try {
        $dependentServices = Get-Service -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ServicesDependedOn | Where-Object { $_.Name -eq $sqlServiceName }
            }

        foreach ($svc in $dependentServices) {
            $issues.Add([PSCustomObject]@{
                Typ     = 'Windows-Dienst'
                Scope   = 'Dienst-Abhängigkeit'
                Name    = $svc.Name
                Detail  = "DisplayName: $($svc.DisplayName) | Status: $($svc.Status)"
                Schwere = 'HOCH'
            })
            Write-UpgradeLog "Dienst-Abhängigkeit gefunden: $($svc.Name) ($($svc.DisplayName))" -Level WARN
        }
    }
    catch {
        Write-UpgradeLog "Fehler beim Prüfen von Dienst-Abhängigkeiten: $_" -Level WARN
    }
    #endregion

    #region --- Ergebnis ausgeben und speichern ---
    $allFindings = @($issues) + @($warnings)

    # Als CSV speichern
    $csvPath = Join-Path $OutputPath 'Dependencies_Report.csv'
    if ($allFindings.Count -gt 0) {
        $allFindings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-UpgradeLog "Abhängigkeitsbericht gespeichert: $csvPath" -Level INFO
    }

    # Zusammenfassung
    $highCount   = ($issues   | Where-Object { $_.Schwere -eq 'HOCH'   }).Count
    $medCount    = ($warnings | Where-Object { $_.Schwere -eq 'MITTEL' }).Count
    $lowCount    = ($warnings | Where-Object { $_.Schwere -in 'NIEDRIG','INFO' }).Count

    Write-UpgradeLog "--- Abhängigkeitsprüfung Ergebnis ---" -Level INFO
    Write-UpgradeLog "Kritische Abhängigkeiten (HOCH):   $highCount" -Level $(if ($highCount -gt 0) {'WARN'} else {'INFO'})
    Write-UpgradeLog "Warnungen (MITTEL):                $medCount"  -Level INFO
    Write-UpgradeLog "Hinweise (NIEDRIG/INFO):           $lowCount"  -Level INFO

    if ($issues.Count -gt 0) {
        Write-Host ""
        Write-Host "Kritische Abhängigkeiten gefunden:" -ForegroundColor Red
        $issues | Format-Table -AutoSize | Out-Host
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Warnungen / Hinweise:" -ForegroundColor Yellow
        $warnings | Format-Table -AutoSize | Out-Host
    }

    # Entscheidung bei kritischen Abhängigkeiten
    $canProceed = $true
    if ($issues.Count -gt 0) {
        if ($WarnOnly) {
            Write-UpgradeLog "WarnOnly-Modus: Kritische Abhängigkeiten werden ignoriert." -Level WARN
        }
        else {
            $canProceed = Invoke-WithConfirmation `
                -Message "$highCount kritische Abhängigkeit(en) gefunden. Trotzdem fortfahren?" `
                -WarningDetail "Bitte sicherstellen, dass abhängige Dienste/Anwendungen angepasst wurden." `
                -Type YesNo
        }
    }

    return [PSCustomObject]@{
        CanProceed    = $canProceed
        Issues        = $issues
        Warnings      = $warnings
        ReportPath    = $csvPath
        HighCount     = $highCount
        MediumCount   = $medCount
        LowCount      = $lowCount
    }
    #endregion
}
