#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert SQL Server Logins inkl. Passwort-Hashes als T-SQL Skript.
.DESCRIPTION
    Exportiert:
    - SQL Logins mit Passwort-Hash (über DAC oder sys.sql_logins)
    - Windows Logins / Gruppen
    - Server Rollen und deren Mitglieder
    - Login-Berechtigungen auf Server-Ebene (GRANT/DENY)
    - Default Database und Language Einstellungen
    - Zuordnung zu Server-Rollen
.NOTES
    Passwort-Hashes erfordern sysadmin-Rechte.
    Für DAC-Verbindung muss 'remote admin connections' aktiviert sein
    wenn das Script remote ausgeführt wird.
#>

. "$PSScriptRoot\Common\Write-UpgradeLog.ps1"

function Backup-SQLLogins {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlInstance,           # Instanz-Name, z.B. 'localhost' oder 'localhost\INST01'

        [Parameter(Mandatory)]
        [string]$OutputPath,            # Pfad zum Logins-Unterverzeichnis

        [System.Management.Automation.PSCredential]
        $SqlCredential,                 # Für SQL-Auth, sonst Windows-Auth

        [switch]$IncludeDisabled,       # Deaktivierte Logins ebenfalls exportieren
        [switch]$ExcludeSystemLogins    # SA, ##MS_...-Logins ausschliessen
    )

    Write-UpgradeLog "Login-Sicherung gestartet für: $SqlInstance" -Level SECTION

    #region --- Verbindung aufbauen ---
    try {
        $connectParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }

        $server = Connect-DbaInstance @connectParams
        Write-UpgradeLog "Verbunden mit: $($server.Name) (Version: $($server.VersionString))" -Level INFO
    }
    catch {
        Write-UpgradeLog "Verbindung fehlgeschlagen: $_" -Level ERROR
        throw
    }
    #endregion

    #region --- Logins exportieren (dbatools) ---
    Write-UpgradeLog "Exportiere Logins mit dbatools..." -Level INFO

    try {
        $exportFile = Join-Path $OutputPath 'Logins_Export.sql'

        $exportParams = @{
            SqlInstance = $server
            FilePath    = $exportFile
            Passthru    = $false
        }
        if (-not $IncludeDisabled)    { $exportParams.ExcludeLogin = @() }
        if ($ExcludeSystemLogins)     { $exportParams.ExcludeSystemLogins = $true }

        # dbatools Export-DbaLogin beinhaltet Passwort-Hashes für SQL Logins
        Export-DbaLogin @exportParams
        Write-UpgradeLog "dbatools Login-Export abgeschlossen: $exportFile" -Level SUCCESS
    }
    catch {
        Write-UpgradeLog "dbatools Export-DbaLogin fehlgeschlagen, versuche manuellen Export: $_" -Level WARN
        $exportFile = $null
    }
    #endregion

    #region --- Manueller Export als Fallback / Ergänzung ---
    Write-UpgradeLog "Erstelle ergänzendes manuelles T-SQL Login-Skript..." -Level INFO

    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- SQL Server Login Sicherung")
    $null = $sb.AppendLine("-- Instanz  : $SqlInstance")
    $null = $sb.AppendLine("-- Erstellt : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("USE [master]")
    $null = $sb.AppendLine("GO")
    $null = $sb.AppendLine("")

    # T-SQL Query für Passwort-Hashes und alle relevanten Eigenschaften
    $loginQuery = @"
SELECT
    l.name                                          AS LoginName,
    l.type_desc                                     AS LoginType,
    l.is_disabled                                   AS IsDisabled,
    l.default_database_name                         AS DefaultDatabase,
    l.default_language_name                         AS DefaultLanguage,
    l.is_policy_checked                             AS IsPolicyChecked,
    l.is_expiration_checked                         AS IsExpirationChecked,
    CONVERT(VARCHAR(MAX), LOGINPROPERTY(l.name,'PasswordHash'), 1) AS PasswordHash,
    l.sid                                           AS SID,
    CONVERT(VARCHAR(MAX), l.sid, 1)                 AS SIDHex,
    l.create_date                                   AS CreateDate,
    l.modify_date                                   AS ModifyDate
FROM sys.server_principals l
LEFT JOIN sys.sql_logins sl ON l.principal_id = sl.principal_id
WHERE l.type IN ('S','U','G')   -- SQL, Windows User, Windows Group
  AND l.name NOT LIKE '##%'     -- interne Service-Accounts ausschliessen
  $(if ($ExcludeSystemLogins) { "AND l.name NOT IN ('sa','BUILTIN\\Administrators')" } else { '' })
  $(if (-not $IncludeDisabled) { "AND l.is_disabled = 0" } else { '' })
ORDER BY l.type_desc, l.name
"@

    try {
        $logins = Invoke-DbaQuery -SqlInstance $server -Query $loginQuery
        Write-UpgradeLog "$($logins.Count) Logins gefunden." -Level INFO
    }
    catch {
        Write-UpgradeLog "Fehler beim Abrufen der Logins: $_" -Level ERROR
        throw
    }

    # Server-Rollen-Mitgliedschaften
    $roleQuery = @"
SELECT
    r.name  AS RoleName,
    m.name  AS MemberName,
    m.type_desc AS MemberType
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE m.name NOT LIKE '##%'
ORDER BY r.name, m.name
"@

    $roleMembers = Invoke-DbaQuery -SqlInstance $server -Query $roleQuery

    # Server-Level Berechtigungen
    $permQuery = @"
SELECT
    p.state_desc        AS PermState,
    p.permission_name   AS Permission,
    pr.name             AS LoginName,
    pr.type_desc        AS LoginType
FROM sys.server_permissions p
JOIN sys.server_principals pr ON p.grantee_principal_id = pr.principal_id
WHERE pr.name NOT LIKE '##%'
  AND pr.type IN ('S','U','G')
ORDER BY pr.name, p.permission_name
"@

    $serverPerms = Invoke-DbaQuery -SqlInstance $server -Query $permQuery

    #endregion

    #region --- T-SQL Skript generieren ---

    foreach ($login in $logins) {
        $null = $sb.AppendLine("-- Login: $($login.LoginName) [$($login.LoginType)]")

        switch ($login.LoginType) {
            'SQL_LOGIN' {
                if ($login.PasswordHash) {
                    $null = $sb.AppendLine(@"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($login.LoginName)')
BEGIN
    CREATE LOGIN [$($login.LoginName)]
    WITH PASSWORD     = $($login.PasswordHash) HASHED,
         SID          = $($login.SIDHex),
         DEFAULT_DATABASE = [$($login.DefaultDatabase)],
         DEFAULT_LANGUAGE = [$($login.DefaultLanguage)],
         CHECK_POLICY      = $(if($login.IsPolicyChecked){'ON'}else{'OFF'}),
         CHECK_EXPIRATION  = $(if($login.IsExpirationChecked){'ON'}else{'OFF'})
END
GO
"@)
                }
                else {
                    # Kein Hash verfügbar (z.B. nicht genug Rechte)
                    $null = $sb.AppendLine("-- WARNUNG: Kein Passwort-Hash verfügbar für $($login.LoginName)")
                    $null = $sb.AppendLine(@"
-- IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($login.LoginName)')
-- BEGIN
--     CREATE LOGIN [$($login.LoginName)] WITH PASSWORD = N'<NEUES_PASSWORT>',
--          DEFAULT_DATABASE = [$($login.DefaultDatabase)]
-- END
-- GO
"@)
                }
            }
            { $_ -in 'WINDOWS_LOGIN','WINDOWS_GROUP' } {
                $null = $sb.AppendLine(@"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($login.LoginName)')
BEGIN
    CREATE LOGIN [$($login.LoginName)] FROM WINDOWS
    WITH DEFAULT_DATABASE = [$($login.DefaultDatabase)],
         DEFAULT_LANGUAGE = [$($login.DefaultLanguage)]
END
GO
"@)
            }
        }

        # Login deaktivieren wenn nötig
        if ($login.IsDisabled) {
            $null = $sb.AppendLine("ALTER LOGIN [$($login.LoginName)] DISABLE")
            $null = $sb.AppendLine("GO")
        }

        $null = $sb.AppendLine("")
    }

    # Server-Rollen-Mitgliedschaften
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- Server-Rollen Mitgliedschaften")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("")

    foreach ($rm in $roleMembers) {
        # sysadmin-Mitgliedschaft über sp_addsrvrolemember
        $null = $sb.AppendLine(@"
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($rm.MemberName)')
    AND NOT EXISTS (
        SELECT 1 FROM sys.server_role_members rm2
        JOIN sys.server_principals r2 ON rm2.role_principal_id = r2.principal_id
        JOIN sys.server_principals m2 ON rm2.member_principal_id = m2.principal_id
        WHERE r2.name = N'$($rm.RoleName)' AND m2.name = N'$($rm.MemberName)'
    )
BEGIN
    ALTER SERVER ROLE [$($rm.RoleName)] ADD MEMBER [$($rm.MemberName)]
END
GO
"@)
    }

    # Server-Berechtigungen
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("-- Server-Level Berechtigungen")
    $null = $sb.AppendLine("-- ============================================================")
    $null = $sb.AppendLine("")

    foreach ($perm in $serverPerms) {
        $stmt = switch ($perm.PermState) {
            'GRANT'        { "GRANT $($perm.Permission) TO [$($perm.LoginName)]" }
            'GRANT_WITH_GRANT_OPTION' { "GRANT $($perm.Permission) TO [$($perm.LoginName)] WITH GRANT OPTION" }
            'DENY'         { "DENY $($perm.Permission) TO [$($perm.LoginName)]"  }
            default        { "-- UNBEKANNT: $($perm.PermState) $($perm.Permission) TO [$($perm.LoginName)]" }
        }
        $null = $sb.AppendLine($stmt)
        $null = $sb.AppendLine("GO")
    }

    # Manuelles Skript speichern
    $manualFile = Join-Path $OutputPath 'Logins_Manual.sql'
    $sb.ToString() | Out-File -FilePath $manualFile -Encoding UTF8
    Write-UpgradeLog "Manuelles Login-Skript gespeichert: $manualFile" -Level SUCCESS
    #endregion

    #region --- Login-Inventar als CSV ---
    $inventarFile = Join-Path $OutputPath 'Logins_Inventar.csv'
    $logins | Select-Object LoginName, LoginType, IsDisabled, DefaultDatabase, DefaultLanguage,
                             IsPolicyChecked, IsExpirationChecked, CreateDate, ModifyDate |
              Export-Csv -Path $inventarFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-UpgradeLog "Login-Inventar gespeichert: $inventarFile" -Level INFO
    #endregion

    Write-UpgradeLog "Login-Sicherung abgeschlossen. $($logins.Count) Logins exportiert." -Level SUCCESS

    return [PSCustomObject]@{
        LoginCount    = $logins.Count
        ExportFile    = $exportFile
        ManualFile    = $manualFile
        InventarFile  = $inventarFile
        RoleMembers   = $roleMembers.Count
        ServerPerms   = $serverPerms.Count
    }
}
