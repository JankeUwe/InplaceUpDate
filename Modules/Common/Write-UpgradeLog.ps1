#Requires -Version 5.1
<#
.SYNOPSIS
    Zentrale Logging-Funktion für das SQL Upgrade Tool.
.DESCRIPTION
    Schreibt formatierte Log-Einträge in Konsole und Logdatei.
    Unterstützt die Level: INFO, WARN, ERROR, SUCCESS, SECTION
#>

function Write-UpgradeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR','SUCCESS','SECTION','DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogFile,          # Pfad zur Logdatei (optional, nimmt globale Variable)
        [switch]$NoConsole         # Nur in Datei schreiben
    )

    # Globale Logdatei verwenden falls vorhanden
    if (-not $LogFile -and $Global:UpgradeLogFile) {
        $LogFile = $Global:UpgradeLogFile
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine   = "[$timestamp] [$Level] $Message"

    # Konsolenausgabe mit Farbe
    if (-not $NoConsole) {
        switch ($Level) {
            'INFO'    { Write-Host $logLine -ForegroundColor Cyan    }
            'WARN'    { Write-Host $logLine -ForegroundColor Yellow  }
            'ERROR'   { Write-Host $logLine -ForegroundColor Red     }
            'SUCCESS' { Write-Host $logLine -ForegroundColor Green   }
            'DEBUG'   { Write-Host $logLine -ForegroundColor Gray    }
            'SECTION' {
                $sep = '=' * 80
                Write-Host ""
                Write-Host $sep        -ForegroundColor Magenta
                Write-Host "  $Message" -ForegroundColor Magenta
                Write-Host $sep        -ForegroundColor Magenta
                Write-Host ""
                $logLine = "[$timestamp] [SECTION] === $Message ==="
            }
        }
    }

    # In Datei schreiben
    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logLine -Encoding UTF8
        }
        catch {
            Write-Host "WARNUNG: Log konnte nicht geschrieben werden: $_" -ForegroundColor Yellow
        }
    }
}

function Initialize-UpgradeLog {
    <#
    .SYNOPSIS
        Initialisiert das Ausgabeverzeichnis und die Logdatei.
    .OUTPUTS
        PSCustomObject mit OutputRoot und LogFile Pfaden
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseOutputPath,

        [string]$InstanceName = 'Default'
    )

    $timestamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $safeName   = $InstanceName -replace '[\\/:*?"<>|]', '_'
    $outputRoot = Join-Path $BaseOutputPath "$timestamp`_$safeName"

    # Unterverzeichnisse anlegen
    $subDirs = @(
        'Logins',
        'LinkedServers',
        'SSIS_Legacy',
        'SSIS_Catalog',
        'SSRS',
        'SSAS',
        'Dependencies',
        'Config'
    )

    foreach ($dir in $subDirs) {
        $null = New-Item -Path (Join-Path $outputRoot $dir) -ItemType Directory -Force
    }

    $logFile = Join-Path $outputRoot 'SQLUpgrade_Report.log'
    $null    = New-Item -Path $logFile -ItemType File -Force

    # Global setzen damit Write-UpgradeLog ohne Parameter funktioniert
    $Global:UpgradeLogFile   = $logFile
    $Global:UpgradeOutputDir = $outputRoot

    Write-UpgradeLog "Ausgabeverzeichnis erstellt: $outputRoot" -Level INFO

    return [PSCustomObject]@{
        OutputRoot = $outputRoot
        LogFile    = $logFile
        Timestamp  = $timestamp
    }
}

function Invoke-WithConfirmation {
    <#
    .SYNOPSIS
        Zeigt eine Warnung und fragt nach Bestätigung bevor eine Aktion ausgeführt wird.
    .OUTPUTS
        $true wenn der Benutzer bestätigt, $false wenn abgelehnt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$WarningDetail,

        [ValidateSet('YesNo','YesNoCancel')]
        [string]$Type = 'YesNo'
    )

    Write-Host ""
    Write-Host "ACHTUNG: $Message" -ForegroundColor Yellow
    if ($WarningDetail) {
        Write-Host "         $WarningDetail" -ForegroundColor Yellow
    }
    Write-Host ""

    $valid = $false
    while (-not $valid) {
        if ($Type -eq 'YesNoCancel') {
            Write-Host "Eingabe: [J]a / [N]ein / [A]bbrechen: " -ForegroundColor White -NoNewline
        }
        else {
            Write-Host "Eingabe: [J]a / [N]ein: " -ForegroundColor White -NoNewline
        }

        $input = (Read-Host).Trim().ToUpper()

        switch ($input) {
            { $_ -in 'J','JA','Y','YES' } {
                $valid = $true
                Write-UpgradeLog "Benutzerbestätigung: JA für '$Message'" -Level INFO
                return $true
            }
            { $_ -in 'N','NEIN','NO' } {
                $valid = $true
                Write-UpgradeLog "Benutzerbestätigung: NEIN für '$Message'" -Level INFO
                return $false
            }
            { $_ -in 'A','ABBRECHEN','C','CANCEL' -and $Type -eq 'YesNoCancel' } {
                $valid = $true
                Write-UpgradeLog "Benutzerbestätigung: ABBRECHEN für '$Message'" -Level WARN
                throw "Benutzer hat den Vorgang abgebrochen."
            }
            default {
                Write-Host "Ungültige Eingabe. Bitte J oder N eingeben." -ForegroundColor Red
            }
        }
    }
}
