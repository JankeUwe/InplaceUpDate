#Requires -Version 5.1
<#
.SYNOPSIS
    Interaktive Prompt-Helfer für den SQL Upgrade Wizard.
.DESCRIPTION
    Kleine Bausteine für geführte Konsolen-Eingaben (Text mit Default/Validierung,
    Auswahlmenüs, Ja/Nein-Fragen, SQL-Anmeldeinformationen, Instanz-Erkennung).
    Ergänzt Write-UpgradeLog.ps1 (Farben/Logging) und Invoke-WithConfirmation
    (Warn-Bestätigung vor destruktiven Aktionen) um neutrale Eingabe-Prompts.
#>

function Show-WizardStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [int]$Total,
        [Parameter(Mandatory)] [string]$Title
    )

    Write-UpgradeLog "Schritt $Number von $Total`: $Title" -Level SECTION
}

function Read-WizardText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ValidationMessage = 'Ungültige Eingabe.',
        [switch]$AllowEmpty
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        Write-Host "$Prompt$suffix`: " -ForegroundColor White -NoNewline
        $value = (Read-Host).Trim()

        if (-not $value) {
            if ($Default) { $value = $Default }
            elseif ($AllowEmpty) { return '' }
            else {
                Write-Host "Eingabe darf nicht leer sein." -ForegroundColor Red
                continue
            }
        }

        if ($Validate -and -not (& $Validate $value)) {
            Write-Host $ValidationMessage -ForegroundColor Red
            continue
        }

        return $value
    }
}

function Read-WizardYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [ValidateSet('J', 'N')] [string]$Default = 'N'
    )

    $hint = if ($Default -eq 'J') { '[J/n]' } else { '[j/N]' }

    while ($true) {
        Write-Host "$Prompt $hint`: " -ForegroundColor White -NoNewline
        $input = (Read-Host).Trim().ToUpper()

        if (-not $input) { $input = $Default }

        switch ($input) {
            { $_ -in 'J', 'JA', 'Y', 'YES' } { return $true }
            { $_ -in 'N', 'NEIN', 'NO' }     { return $false }
            default { Write-Host "Bitte J oder N eingeben." -ForegroundColor Red }
        }
    }
}

function Read-WizardChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] [array]$Options,      # Objekte mit .Label und .Value
        [int]$DefaultIndex = 1,
        [switch]$AllowCustom,
        [string]$CustomLabel = 'Eigenen Wert eingeben'
    )

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1) - $($Options[$i].Label)"
    }
    if ($AllowCustom) {
        Write-Host "  0 - $CustomLabel"
    }

    while ($true) {
        Write-Host "Auswahl [$DefaultIndex]`: " -ForegroundColor White -NoNewline
        $input = (Read-Host).Trim()
        if (-not $input) { $input = "$DefaultIndex" }

        if ($input -eq '0' -and $AllowCustom) {
            return $null
        }

        $idx = 0
        if ([int]::TryParse($input, [ref]$idx) -and $idx -ge 1 -and $idx -le $Options.Count) {
            return $Options[$idx - 1].Value
        }

        Write-Host "Bitte eine Zahl zwischen $(if($AllowCustom){'0'}else{'1'}) und $($Options.Count) eingeben." -ForegroundColor Red
    }
}

function Read-WizardCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstanceLabel
    )

    $useSqlAuth = Read-WizardYesNo -Prompt "SQL-Authentifizierung für '$InstanceLabel' verwenden? (sonst Windows-Auth)" -Default N
    if (-not $useSqlAuth) { return $null }

    return Get-Credential -Message "SQL-Anmeldeinformationen für '$InstanceLabel'"
}

function Wait-ForWizardContinue {
    [CmdletBinding()]
    param(
        [string]$Message = 'Bereit zum Fortfahren?'
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    Write-Host "[Enter] zum Fortfahren drücken..." -ForegroundColor White -NoNewline
    Read-Host | Out-Null
}

function Get-LocalSQLInstances {
    <#
    .SYNOPSIS
        Ermittelt lokal installierte SQL Server Instanzen für die Wizard-Auswahl.
    .OUTPUTS
        PSCustomObject[] mit SqlInstance / InstanceName
    #>
    [CmdletBinding()]
    param()

    $result = [System.Collections.Generic.List[PSCustomObject]]::new()

    $instKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path $instKey) {
        try {
            $props = Get-ItemProperty $instKey -ErrorAction SilentlyContinue
            foreach ($prop in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
                $instanceName = $prop.Name
                $sqlInstance  = if ($instanceName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instanceName" }

                $result.Add([PSCustomObject]@{
                    SqlInstance  = $sqlInstance
                    InstanceName = $instanceName
                })
            }
        }
        catch {
            Write-UpgradeLog "Instanz-Erkennung fehlgeschlagen: $_" -Level WARN
        }
    }

    return $result
}
