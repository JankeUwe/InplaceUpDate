#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert Linked Server Definitionen und Credentials als T-SQL Skript.
.DESCRIPTION
    Exportiert:
    - Linked Server Definitionen (Provider, DataSource, Catalog)
    - Provider-Optionen (RPC, LazySchemaValidation etc.)
    - Linked Login Zuordnungen (sys.linked_logins)
    - Passwörter können NICHT exportiert werden (SQL Server schränkt das ein)
      → Platzhalter werden generiert mit Hinweiskommentar
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-LinkedServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [System.Management.Automation.PSCredential]
        $SqlCredential
    )

    Write-UpgradeLog "Linked Server Sicherung gestartet für: $SqlInstance" -Level SECTION

    #region --- Verbindung aufbauen ---
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

    #region --- Linked Server Daten abfragen ---
    $lsQuery = @"
SELECT
    ls.name                     AS LinkedServerName,
    ls.product                  AS Product,
    ls.provider                 AS Provider,
    ls.data_source              AS DataSource,
    ls.location                 AS Location,
    ls.provider_string          AS ProviderString,
    ls.catalog                  AS Catalog,
    ls.is_linked                AS IsLinked,
    ls.is_remote_login_enabled  AS IsRemoteLoginEnabled,
    ls.is_rpc_out_enabled       AS IsRpcOutEnabled,
    ls.is_data_access_enabled   AS IsDataAccessEnabled,
    ls.is_collation_compatible  AS IsCollationCompatible,
    ls.uses_remote_collation    AS UsesRemoteCollation,
    ls.collation_name           AS CollationName,
    ls.connect_timeout          AS ConnectTimeout,
    ls.query_timeout            AS QueryTimeout,
    ls.is_remote_proc_transaction_promotion_enabled AS IsDistributedTransEnabled,
    ls.modify_date              AS ModifyDate
FROM sys.servers ls
WHERE ls.is_linked = 1
ORDER BY ls.name
"@

    $linkedLoginQuery = @"
SELECT
    s.name          AS LinkedServerName,
    ll.uses_self_credentials AS UsesSelfCredentials,
    ll.remote_name  AS RemoteLoginName,
    -- Passwort ist nicht auslesbar, nur Indikator ob eines gesetzt ist
    CASE WHEN ll.modifier_id IS NOT NULL THEN 1 ELSE 0 END AS HasPassword,
    sp.name         AS LocalLoginName,
    sp.type_desc    AS LocalLoginType
FROM sys.linked_logins ll
JOIN sys.servers s       ON ll.server_id = s.server_id
LEFT JOIN sys.server_principals sp ON ll.local_principal_id = sp.principal_id
ORDER BY s.name, sp.name
"@

    try {
        $linkedServers = Invoke-DbaQuery -SqlInstance $server -Query $lsQuery
        $linkedLogins  = Invoke-DbaQuery -SqlInstance $server -Query $linkedLoginQuery
        Write-UpgradeLog "$($linkedServers.Count) Linked Server gefunden." -Level INFO
    }
    catch {
        Write-UpgradeLog "Fehler beim Abfragen der Linked Server: $_" -Level ERROR
        throw
    }
    #endregion

    if ($linkedServers.Count -eq 0) {
        Write-UpgradeLog "Keine Linked Server vorhanden - überspringe." -Level INFO
        return [PSCustomObject]@{ LinkedServerCount = 0 }
    }

    #region --- T-SQL Skript generieren ---
    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- Linked Server Sicherung")
    $null = $sb.AppendLine("-- Instanz  : $SqlInstance")
    $null = $sb.AppendLine("-- Erstellt : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine("-- HINWEIS  : Passwörter können nicht automatisch gesichert werden.")
    $null = $sb.AppendLine("--            Stellen mit <PASSWORT> müssen manuell befüllt werden.")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("USE [master]")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine("")

    foreach ($ls in $linkedServers) {
        $null = $sb.AppendLine("-- ------------------------------------------------------------")
        $null = $sb.AppendLine("-- Linked Server: $($ls.LinkedServerName)")
        $null = $sb.AppendLine("-- Geändert am  : $($ls.ModifyDate)")
        $null = $sb.AppendLine("-- ------------------------------------------------------------")
        $null = $sb.AppendLine("")

        # Bestehenden Linked Server entfernen (Drop-Schutz)
        $null = $sb.AppendLine("IF EXISTS (SELECT 1 FROM sys.servers WHERE name = N'$($ls.LinkedServerName)' AND is_linked = 1)")
        $null = $sb.AppendLine("BEGIN")
        $null = $sb.AppendLine("    EXEC master.dbo.sp_dropserver")
        $null = $sb.AppendLine("        @server     = N'$($ls.LinkedServerName)',")
        $null = $sb.AppendLine("        @droplogins = 'droplogins'")
        $null = $sb.AppendLine("END")
        $null = $sb.AppendLine("GO")
        $null = $sb.AppendLine("")

        # sp_addlinkedserver
        $addCmd  = "EXEC master.dbo.sp_addlinkedserver`n"
        $addCmd += "    @server       = N'$($ls.LinkedServerName)',`n"
        $addCmd += "    @srvproduct   = N'$($ls.Product)',`n"
        $addCmd += "    @provider     = N'$($ls.Provider)'"

        if ($ls.DataSource)     { $addCmd += ",`n    @datasrc      = N'$($ls.DataSource)'" }
        if ($ls.Location)       { $addCmd += ",`n    @location     = N'$($ls.Location)'"   }
        if ($ls.ProviderString) { $addCmd += ",`n    @provstr      = N'$($ls.ProviderString)'" }
        if ($ls.Catalog)        { $addCmd += ",`n    @catalog      = N'$($ls.Catalog)'"    }

        $null = $sb.AppendLine($addCmd)
        $null = $sb.AppendLine("GO")
        $null = $sb.AppendLine("")

        # sp_serveroption für alle relevanten Flags
        $options = @(
            @{ Name = 'rpc';                      Value = if ($ls.IsRemoteLoginEnabled)          {'true'} else {'false'} },
            @{ Name = 'rpc out';                  Value = if ($ls.IsRpcOutEnabled)                {'true'} else {'false'} },
            @{ Name = 'data access';              Value = if ($ls.IsDataAccessEnabled)            {'true'} else {'false'} },
            @{ Name = 'collation compatible';     Value = if ($ls.IsCollationCompatible)          {'true'} else {'false'} },
            @{ Name = 'use remote collation';     Value = if ($ls.UsesRemoteCollation)            {'true'} else {'false'} },
            @{ Name = 'dist';                     Value = if ($ls.IsDistributedTransEnabled)      {'true'} else {'false'} }
        )

        if ($ls.CollationName) {
            $null = $sb.AppendLine("EXEC master.dbo.sp_serveroption")
            $null = $sb.AppendLine("    @server      = N'$($ls.LinkedServerName)',")
            $null = $sb.AppendLine("    @optname     = N'collation name',")
            $null = $sb.AppendLine("    @optvalue    = N'$($ls.CollationName)'")
            $null = $sb.AppendLine("GO")
        }
        if ($ls.ConnectTimeout -gt 0) {
            $null = $sb.AppendLine("EXEC master.dbo.sp_serveroption")
            $null = $sb.AppendLine("    @server      = N'$($ls.LinkedServerName)',")
            $null = $sb.AppendLine("    @optname     = N'connect timeout',")
            $null = $sb.AppendLine("    @optvalue    = N'$($ls.ConnectTimeout)'")
            $null = $sb.AppendLine("GO")
        }
        if ($ls.QueryTimeout -gt 0) {
            $null = $sb.AppendLine("EXEC master.dbo.sp_serveroption")
            $null = $sb.AppendLine("    @server      = N'$($ls.LinkedServerName)',")
            $null = $sb.AppendLine("    @optname     = N'query timeout',")
            $null = $sb.AppendLine("    @optvalue    = N'$($ls.QueryTimeout)'")
            $null = $sb.AppendLine("GO")
        }

        foreach ($opt in $options) {
            $null = $sb.AppendLine("EXEC master.dbo.sp_serveroption")
            $null = $sb.AppendLine("    @server      = N'$($ls.LinkedServerName)',")
            $null = $sb.AppendLine("    @optname     = N'$($opt.Name)',")
            $null = $sb.AppendLine("    @optvalue    = N'$($opt.Value)'")
            $null = $sb.AppendLine("GO")
        }

        $null = $sb.AppendLine("")

        # Linked Logins für diesen Server
        $lsLogins = $linkedLogins | Where-Object { $_.LinkedServerName -eq $ls.LinkedServerName }

        foreach ($ll in $lsLogins) {
            $null = $sb.AppendLine("-- Linked Login: $(if($ll.LocalLoginName){"Lokal: $($ll.LocalLoginName)"}else{'(Default/Alle)'}) -> Remote: $($ll.RemoteLoginName)")

            if ($ll.UsesSelfCredentials) {
                # Self-Credentials: kein Remote-Login
                $localPart = if ($ll.LocalLoginName) { "@locallogin = N'$($ll.LocalLoginName)'" } else { "@locallogin = NULL" }
                $null = $sb.AppendLine("EXEC master.dbo.sp_addlinkedsrvlogin")
                $null = $sb.AppendLine("    @rmtsrvname   = N'$($ls.LinkedServerName)',")
                $null = $sb.AppendLine("    @useself      = N'True',")
                $null = $sb.AppendLine("    $localPart")
                $null = $sb.AppendLine("GO")
            }
            else {
                $localPart = if ($ll.LocalLoginName) { "@locallogin = N'$($ll.LocalLoginName)'" } else { "@locallogin = NULL" }
                $pwHint    = if ($ll.HasPassword) { "<PASSWORT_EINTRAGEN>" } else { "" }
                $null = $sb.AppendLine("EXEC master.dbo.sp_addlinkedsrvlogin")
                $null = $sb.AppendLine("    @rmtsrvname   = N'$($ls.LinkedServerName)',")
                $null = $sb.AppendLine("    @useself      = N'False',")
                $null = $sb.AppendLine("    $localPart,")
                $null = $sb.AppendLine("    @rmtuser      = N'$($ll.RemoteLoginName)',")
                $null = $sb.AppendLine("    @rmtpassword  = N'$pwHint'   -- Passwort muss manuell gesetzt werden!")
                $null = $sb.AppendLine("GO")
            }
            $null = $sb.AppendLine("")
        }

        $null = $sb.AppendLine("")
    }

    # Skript speichern
    $outputFile = Join-Path $OutputPath 'LinkedServers.sql'
    $sb.ToString() | Out-File -FilePath $outputFile -Encoding UTF8
    Write-UpgradeLog "Linked Server Skript gespeichert: $outputFile" -Level SUCCESS
    #endregion

    #region --- Inventar als CSV ---
    $csvFile = Join-Path $OutputPath 'LinkedServers_Inventar.csv'
    $linkedServers | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'

    $csvLoginsFile = Join-Path $OutputPath 'LinkedServers_Logins_Inventar.csv'
    $linkedLogins  | Export-Csv -Path $csvLoginsFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    #endregion

    # Warnung wegen Passwörtern
    $withPwd = ($linkedLogins | Where-Object { $_.HasPassword -and -not $_.UsesSelfCredentials }).Count
    if ($withPwd -gt 0) {
        Write-UpgradeLog "HINWEIS: $withPwd Linked Login(s) haben Passwörter die MANUELL nach der Wiederherstellung gesetzt werden müssen!" -Level WARN
    }

    Write-UpgradeLog "Linked Server Sicherung abgeschlossen: $($linkedServers.Count) Server, $($linkedLogins.Count) Logins." -Level SUCCESS

    return [PSCustomObject]@{
        LinkedServerCount = $linkedServers.Count
        LinkedLoginCount  = $linkedLogins.Count
        WithPasswordCount = $withPwd
        OutputFile        = $outputFile
        CsvFile           = $csvFile
    }
}
