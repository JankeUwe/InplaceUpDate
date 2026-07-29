#Requires -Version 5.1
<#
.SYNOPSIS
    Persistiert den Fortschritt des SQL Upgrade Wizards.
.DESCRIPTION
    Der Wizard läuft über einen Neustart des Servers hinweg (Deinstallation ->
    manuelle Neuinstallation -> Wiederherstellung). Der Zustand wird als JSON
    im Backup-Set-Verzeichnis abgelegt; ein Zeiger unter %ProgramData% erlaubt
    es einem frisch gestarteten Wizard, die letzte Sitzung ohne Nutzereingabe
    wiederzufinden.
#>

$script:WizardStatePointerFile = Join-Path $env:ProgramData 'InplaceUpDate\LastWizardState.txt'

function Save-WizardState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$State
    )

    if (-not $State.BackupSetPath) {
        throw "Save-WizardState: State.BackupSetPath ist erforderlich."
    }

    $State.LastUpdatedAt = (Get-Date).ToString('s')

    $stateFile = Join-Path $State.BackupSetPath 'WizardState.json'
    $State | ConvertTo-Json -Depth 5 | Out-File -FilePath $stateFile -Encoding UTF8

    $pointerDir = Split-Path $script:WizardStatePointerFile -Parent
    if (-not (Test-Path $pointerDir)) {
        $null = New-Item -Path $pointerDir -ItemType Directory -Force
    }
    Set-Content -Path $script:WizardStatePointerFile -Value $State.BackupSetPath -Encoding UTF8

    Write-UpgradeLog "Wizard-Status gespeichert: $stateFile (Phase: $($State.Phase))" -Level DEBUG
}

function Get-WizardState {
    <#
    .OUTPUTS
        PSCustomObject wenn eine gespeicherte Sitzung gefunden wird, sonst $null.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:WizardStatePointerFile)) { return $null }

    $backupSetPath = (Get-Content -Path $script:WizardStatePointerFile -Raw).Trim()
    if (-not $backupSetPath) { return $null }

    $stateFile = Join-Path $backupSetPath 'WizardState.json'
    if (-not (Test-Path $stateFile)) { return $null }

    try {
        return Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-UpgradeLog "Wizard-Status konnte nicht gelesen werden ($stateFile): $_" -Level WARN
        return $null
    }
}

function New-WizardState {
    [CmdletBinding()]
    param(
        [string]$Phase = 'New',
        [string]$SqlInstance,
        [string]$InstanceName,
        [string]$OutputBaseDir,
        [string]$BackupSetPath,
        [string]$SSASServer,
        [string]$SSRSReportServerDB
    )

    return [PSCustomObject]@{
        Phase              = $Phase
        SqlInstance        = $SqlInstance
        InstanceName       = $InstanceName
        OutputBaseDir      = $OutputBaseDir
        BackupSetPath      = $BackupSetPath
        SSASServer         = $SSASServer
        SSRSReportServerDB = $SSRSReportServerDB
        LastUpdatedAt      = (Get-Date).ToString('s')
    }
}
