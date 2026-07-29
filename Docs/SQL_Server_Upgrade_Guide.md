# SQL Server Inplace Upgrade Tool - User Guide

## Table of Contents

1. [Overview](#overview)
2. [Recommended: Guided Wizard](#recommended-guided-wizard)
3. [System Requirements](#system-requirements)
4. [Installation and Preparation](#installation-and-preparation)
5. [Phase 1: Backup - Start-SQLUpgradeBackup.ps1](#phase-1-backup)
6. [Phase 2: Uninstall - Start-SQLUpgradeUninstall.ps1](#phase-2-uninstall)
7. [Phase 3: Reinstall](#phase-3-reinstall)
8. [Phase 4: Restore - Start-SQLUpgradeRestore.ps1](#phase-4-restore)
9. [Backup Directory Structure](#backup-directory-structure)
10. [Frequently Asked Questions](#frequently-asked-questions)
11. [Troubleshooting](#troubleshooting)

---

## Overview

The **SQL Server Inplace Upgrade Tool** is a PowerShell-based solution for safely performing SQL Server upgrades (for example, from SQL Server 2019 to SQL Server 2022 or later).

### What does the tool do?

The tool automates the **four phases** of a safe SQL Server inplace upgrade:

| Phase | Script | Action |
|-------|--------|--------|
| **1. Backup** | `Start-SQLUpgradeBackup.ps1` | Backs up all SQL Server objects: logins, linked servers, SSIS (SSISDB + legacy), SSRS, SSAS, dependencies |
| **2. Uninstall** | `Start-SQLUpgradeUninstall.ps1` | Cleanly uninstalls the old SQL Server version via setup.exe |
| **3. Install** | *Manual* | Installation of the new SQL Server version (not automated by the tool) |
| **4. Restore** | `Start-SQLUpgradeRestore.ps1` | Restores all backed-up objects on the new version (interactive) |

The three PowerShell scripts above can be run individually with parameters (see the phase sections below) - this is the recommended path for automation/scripting. For a manual, interactive upgrade, use the **guided wizard** described next instead of calling the scripts directly.

### What gets backed up?

The backup step secures the following components:

1. **SQL Logins** - server logins including password hashes (sysadmin required)
2. **Linked Servers** - connections to other SQL Server instances
3. **SSIS Catalog (SSISDB)** - all SSIS projects and packages (SQL Server 2012+)
4. **SSIS Legacy (msdb)** - old Integration Services packages from the msdb database
5. **SSRS Reports** - Reporting Services reports, data sources and configuration
6. **SSAS Cubes** - Analysis Services databases and models
7. **Dependencies** - dependency analysis between objects
8. **Inventories as CSV** - documentation of all backed-up objects for traceability

---

## Recommended: Guided Wizard

`Start-SQLUpgradeWizard.ps1` walks you interactively through all three phases (backup,
uninstall, restore) instead of requiring you to know and pass PowerShell parameters by
hand. It asks for every required value with sensible defaults and validation, and it
remembers your progress across the reboot that typically happens between uninstalling
the old version and manually installing the new one.

### Starting the wizard

```powershell
# Via the launcher (recommended, requests elevation automatically)
Start-InplaceUpDate.cmd Wizard

# Or directly
.\Start-SQLUpgradeWizard.ps1
```

`Start-InplaceUpDate.cmd` also offers the wizard as option `0`, which is the default
when no choice is typed.

### What the wizard does

1. **Session detection** - on start, the wizard checks for a previously saved session
   (backup set path, instance, phase reached) and offers to resume it.
2. **Phase 1 - Backup** - detects locally installed SQL Server instances and offers them
   as a pick list, then asks for the output directory, authentication mode, and whether
   to skip SSAS/SSRS. Shows a summary before starting.
3. **Phase 2 - Uninstall** - reuses the backup set from phase 1 (or lets you point at a
   different one), verifies that a backup proof (`Backup_Summary.json`) exists, then
   calls the existing uninstall logic, which asks its own confirmations for cleanup,
   registry removal, and restart.
4. **Manual reinstall gate** - after uninstall, the wizard either exits with instructions
   to reinstall SQL Server manually and re-run the wizard (if a restart was confirmed),
   or waits for you to press Enter once the new installation is complete (if no restart
   was needed).
5. **Phase 3 - Restore** - asks for the new instance name and credentials, then restores
   all objects from the saved backup set.

The wizard is purely an interactive front end for the same `Modules\*.ps1` logic used by
the three standalone scripts - no backup, uninstall, or restore behavior differs between
the wizard and the manual invocation described in the phase sections below.

### Resuming after a reboot

Progress is saved as `WizardState.json` inside the backup set directory, with a pointer
file at `%ProgramData%\InplaceUpDate\LastWizardState.txt`. Simply re-run the wizard (or
`Start-InplaceUpDate.cmd Wizard`) after the reboot and confirm resuming the detected
session - it picks up right where it left off.

---

## System Requirements

### PowerShell

- **PowerShell 5.1** or higher
- Execution policy: `RemoteSigned` or higher
  ```powershell
  Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  ```

### dbatools Module

The tool requires the **dbatools module** for SQL Server automation:

```powershell
# One-time installation
Install-Module dbatools -Scope CurrentUser -Force
Import-Module dbatools
```

**Important:** dbatools must be version 1.0 or later:
```powershell
Get-Module dbatools | Select-Object Version
```

### SQL Server Permissions

- **Sysadmin** on the SQL Server instance (for login and SSIS backup)
- **Database owner (dbo)** on SSISDB, the SSRS ReportServer database, and msdb

### Local Administrator Rights

- **Local administrator** on the upgrade server (for uninstall and reinstall)

### Disk Space

- **At least 5-10 GB** free space in the backup directory (depends on database size and report count)

### Optional: SSAS

If SSAS should be backed up:
- **Microsoft.AnalysisServices assembly** (installed with SSMS or SSAS)
- Loaded automatically if available

---

## Installation and Preparation

### Step 1: Download the tool

```powershell
# Clone from GitHub
git clone https://github.com/JankeUwe/InplaceUpDate.git
cd InplaceUpDate\SQLUpgrade-Tool
```

Or: download directly as a ZIP from https://github.com/JankeUwe/InplaceUpDate

### Step 2: Install dbatools

```powershell
# Open PowerShell as Administrator
Install-Module dbatools -Scope CurrentUser -Force
```

### Step 3: Set the execution policy

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### Step 4: Prepare paths

```powershell
# Create backup directory (e.g. on D: for more space)
New-Item -ItemType Directory -Path "D:\SQLUpgrade_Backup" -Force

# Or default: C:\SQLUpgrade_Backup
New-Item -ItemType Directory -Path "C:\SQLUpgrade_Backup" -Force
```

---

## Phase 1: Backup - Start-SQLUpgradeBackup.ps1

> The guided wizard runs this same logic interactively - see
> [Recommended: Guided Wizard](#recommended-guided-wizard). This section documents the
> script directly for manual or automated use.

### What happens during backup?

The backup script performs the following steps:

1. **Connect to SQL Server** - contacts the SQL Server instance via dbatools
2. **Gather instance information** - SQL Server version, database size, components
3. **Export logins** - all server logins with password hashes (via dbatools or T-SQL fallback)
4. **Export linked servers** - generate CREATE LINKED SERVER scripts
5. **Back up SSIS Catalog** - full SSISDB backup, inventories (folders, projects, packages, environments)
6. **Back up SSIS legacy** - .dtsx files from msdb, generate restore script
7. **Back up SSRS** - reports (.rdl/.rds/.rsd), configuration files, subscriptions, permissions
8. **Back up SSAS** (optional) - cube backups (.abf), XMLA definitions
9. **Analyze dependencies** - identify dependencies between objects
10. **Generate CSV inventories** - full documentation for traceability
11. **Write backup summary** - JSON file with backup metadata and a report log file

### Example: Back up the default instance

```powershell
# Open PowerShell as Administrator
cd C:\SQLUpgrade-Tool

# Simplest form: default instance on localhost
.\Start-SQLUpgradeBackup.ps1

# Result: C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER\
```

**Output during the backup process:**
```
=== SQL Server Inplace Upgrade Tool - Backup Phase ===
Target server: MSSQLSERVER@localhost
Output directory: C:\SQLUpgrade_Backup

[01/15] Connecting to localhost...
[02/15] Gathering instance information...
  Version: SQL Server 2019 (15.0.4249.2)
  Edition: Enterprise
  Service Pack: CU16
[03/15] Exporting logins (5 total)...
  - sa
  - DOMAIN\SQLAdmins
  ...
[04/15] Exporting linked servers (2 total)...
  - PROD_SERVER
  - DATA_WAREHOUSE
[05/15] Backing up SSISDB catalog...
  - Backup successful: SSISDB.bak (2.3 GB)
  - Inventories created: 847 packages in 15 projects
[06/15] Backing up SSIS legacy (msdb)...
  - 23 legacy packages exported
[07/15] Backing up SSRS...
  - 156 reports backed up
  - Configuration files copied
[08/15] Backing up SSAS...
  - 8 cubes backed up
[09/15] Analyzing dependencies...
  - 1,234 dependencies found
[10/15] Generating inventories...
[11/15] Writing backup summary...

Backup completed: 2024-01-15_143022_MSSQLSERVER
Backup directory: C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER\
Log file: ....\SQLUpgrade_Report.log
```

### Parameters: Named instance with a custom output directory

```powershell
.\Start-SQLUpgradeBackup.ps1 `
    -SqlInstance 'SRV-SQL01\SQL2019' `
    -InstanceName 'SQL2019' `
    -OutputBaseDir 'D:\Upgrade_Backup' `
    -SkipSSAS

# -SqlInstance: SQL Server instance (default: localhost)
# -InstanceName: name for the backup directory (default: MSSQLSERVER)
# -OutputBaseDir: base directory (default: C:\SQLUpgrade_Backup)
# -SkipSSAS: skip SSAS backup (if not present)
```

### Parameters: With SQL login credentials

```powershell
$cred = Get-Credential  # Prompts for username and password

.\Start-SQLUpgradeBackup.ps1 `
    -SqlInstance 'SRV-SQL01\SQL2019' `
    -SqlCredential $cred `
    -OutputBaseDir 'D:\Upgrade_Backup'
```

### Parameters: SSRS with a custom database

```powershell
.\Start-SQLUpgradeBackup.ps1 `
    -SqlInstance localhost `
    -SSRSReportServerDB 'ReportServer_Custom' `
    -OutputBaseDir 'D:\Upgrade_Backup'

# Default: ReportServer
# If your SSRS database has a different name, configure it here
```

### Full parameter list

| Parameter | Default | Description |
|-----------|---------|--------------|
| `-SqlInstance` | `localhost` | SQL Server instance |
| `-OutputBaseDir` | `C:\SQLUpgrade_Backup` | Backup output directory |
| `-InstanceName` | `MSSQLSERVER` | Name for the backup folder |
| `-SSASServer` | (same as SqlInstance) | Separate SSAS server |
| `-SSRSReportServerDB` | `ReportServer` | SSRS database name |
| `-SqlCredential` | (Windows auth) | SQL login credentials |
| `-SSISDBBackupPath` | (SQL Server default) | Custom path for the SSISDB backup |
| `-SkipSSAS` | `$false` | Skip SSAS backup |
| `-SkipSSRS` | `$false` | Skip SSRS backup |
| `-Verbose` | (optional) | Detailed output |

---

## Phase 2: Uninstall - Start-SQLUpgradeUninstall.ps1

> The guided wizard runs this same logic interactively - see
> [Recommended: Guided Wizard](#recommended-guided-wizard). This section documents the
> script directly for manual or automated use.

### What happens during uninstall?

The uninstall script performs the following steps:

1. **Backup integrity check** - verifies that a complete backup exists
2. **Stop SQL Server services** - all SQL Server services are stopped
3. **Uninstall features** - SQL Server Engine, SSIS, SSRS, SSAS are removed (via setup.exe)
4. **Clean up the registry** - SQL Server entries are removed from the registry
5. **Delete directories** (optional) - old SQL Server data directories are deleted
6. **Restart** - the server is restarted (optional)

### Example: Uninstall the default instance

```powershell
# Open PowerShell as Administrator
cd C:\SQLUpgrade-Tool

# Uninstall with a reference to the backup set
.\Start-SQLUpgradeUninstall.ps1 `
    -InstanceName MSSQLSERVER `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'

# The tool verifies the backup and then uninstalls SQL Server
```

**Output during uninstall:**
```
=== SQL Server Inplace Upgrade Tool - Uninstall Phase ===
Instance: MSSQLSERVER
Backup set: C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER

[01/05] Validating backup set...
  - Backup directory exists
  - Backup summary found (size: 15.2 GB)
  - Logins_Export.sql present
  - LinkedServers.sql present

[02/05] Stopping SQL Server services...
  - SQL Server (MSSQLSERVER) stopped
  - SQL Server Agent (MSSQLSERVER) stopped
  - SSRS (ReportServer) stopped

[03/05] Uninstalling SQL Server...
  Starting setup.exe with /ACTION=Uninstall
  (This can take 5-10 minutes...)
  - Setup completed

[04/05] Cleaning up the registry...
  - HKLM\SOFTWARE\Microsoft\Microsoft SQL Server entries removed

[05/05] Restarting the server...
  ! Server will restart in 2 minutes...
  ! To cancel: shutdown /a

Uninstall completed.
Next step: manually install SQL Server 2022+
```

### Parameters: With custom features

```powershell
.\Start-SQLUpgradeUninstall.ps1 `
    -InstanceName 'SQL2019' `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_SQL2019' `
    -Features 'SQLEngine,SSIS' `
    -SkipCleanup

# -Features: comma-separated list of features to uninstall
#   (default: all features)
# -SkipCleanup: do NOT delete directories
# -NoRestart: no automatic restart
```

### Full parameter list

| Parameter | Default | Description |
|-----------|---------|--------------|
| `-InstanceName` | `MSSQLSERVER` | Instance to uninstall |
| `-BackupSetPath` | (required) | Path to the backup directory |
| `-SetupPath` | (auto) | Path to setup.exe (auto-detected) |
| `-Features` | (all) | Features to uninstall |
| `-SkipCleanup` | `$false` | Do NOT delete directories |
| `-NoRestart` | `$false` | No automatic restart |

---

## Phase 3: Reinstall

### Manual SQL Server installation

This step is **NOT automated by the tool**. Perform the SQL Server installation manually:

#### Option A: SQL Server Setup Wizard (GUI)

```powershell
# 1. Insert or start the SQL Server installation media
# 2. Run setup.exe
D:\> setup.exe

# 3. In the setup wizard, configure the following:
#    - Installation Type: New SQL Server standalone installation
#    - Instance Configuration: MSSQLSERVER (or the previous name)
#    - Server Configuration: Authentication Mode
#      -> Mixed Mode with sa password (for compatibility)
#    - Features:
#      [x] Database Engine Services (required)
#      [x] SSIS (if SSIS is needed)
#      [x] SSRS (if SSRS is needed)
#      [x] SSAS (if SSAS is needed)
#    - Configure the initial database sizes
```

#### Option B: Command-line installation (unattended)

```powershell
# Example for an unattended installation
D:\> .\setup.exe `
    /Q `
    /ACTION=Install `
    /FEATURES=SQLEngine,SSIS,SSRS,SSAS `
    /INSTANCENAME=MSSQLSERVER `
    /SQLSYSADMINACCOUNTS="DOMAIN\SQLAdmins" `
    /SECURITYMODE=SQL `
    /SAPWD="YourComplexPassword123!"

# /Q = quiet mode (no GUI)
# /ACTION=Install = perform installation
# /FEATURES = features to install
# /INSTANCENAME = instance name (must match the one used at backup time!)
# /SQLSYSADMINACCOUNTS = sysadmin accounts (Windows login or SQL login)
# /SECURITYMODE=SQL = mixed mode (SQL + Windows authentication)
# /SAPWD = sa password (a complex password is required!)
```

### Important notes for reinstallation

- **The instance name MUST match** the one used at backup time (e.g. `MSSQLSERVER`)
- **Mixed mode is recommended** (sa + Windows authentication) for better compatibility
- **Storage paths**: use the same paths as before (if data is not being migrated)
- **Start SQL Server Agent**: important for SSIS job execution
- **Start the SQL Server service**: should happen automatically

---

## Phase 4: Restore - Start-SQLUpgradeRestore.ps1

> The guided wizard runs this same logic interactively - see
> [Recommended: Guided Wizard](#recommended-guided-wizard). This section documents the
> script directly for manual or automated use.

### What happens during restore?

The restore script performs the following steps (interactively):

1. **Connect to the new SQL Server instance**
2. **Backup set validation** - checks integrity and compatibility
3. **Restore logins** - server logins from the dbatools export or T-SQL
4. **Restore linked servers** - execute the CREATE LINKED SERVER scripts
5. **Restore the SSISDB catalog** - restore the backup file (if present)
6. **Restore SSIS legacy** - import .dtsx files into msdb
7. **Restore SSRS** - copy reports and configuration
8. **Restore SSAS** - restore cube backups (optional)
9. **Post-restore checks** - validate object integrity and permissions

### Example: Simple restore

```powershell
# Open PowerShell as Administrator
# (On the new SQL Server, with the new SQL Server version already installed)

cd C:\SQLUpgrade-Tool

# Restore using the backup set
.\Start-SQLUpgradeRestore.ps1 `
    -SqlInstance localhost `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'

# The tool interactively asks which components should be restored
```

**Output during the restore process:**
```
=== SQL Server Inplace Upgrade Tool - Restore Phase ===
Target server: MSSQLSERVER@localhost
Backup set: C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER

[01/09] Validating backup set...
  - Backup directory exists
  - Backup summary found
  - Compatibility: SQL Server 2019 -> 2022 OK

[02/09] Restoring logins...
  Restore server logins? (Y/N): Y
  - 5 logins imported
  - Note: linked server passwords must be set manually

[03/09] Restoring linked servers...
  Restore linked servers? (Y/N): Y
  - 2 linked servers created
  - Note: passwords must be configured manually (see README)

[04/09] Restoring the SSISDB catalog...
  Restore the SSISDB catalog? (Y/N): Y
  Enter the SSISDB master key password: ****
  - SSISDB.bak restored (2.3 GB)
  - 847 packages available in SSISDB

[05/09] Restoring SSIS legacy...
  Restore legacy SSIS packages? (Y/N): Y
  - 23 legacy packages imported into msdb

[06/09] Restoring SSRS...
  Restore SSRS? (Y/N): Y
  - 156 reports imported
  - Configuration files restored

[07/09] Restoring SSAS...
  Restore SSAS cubes? (Y/N): Y
  - 8 cubes restored

[08/09] Post-restore checks...
  - All logins validated
  - SSISDB package compatibility checked
  - SSRS reports loaded

[09/09] Writing restore summary...

Restore completed successfully.
Restore report: .../Restore_Report.log
```

### Parameters: With SQL login credentials

```powershell
$cred = Get-Credential  # Prompts for username and password

.\Start-SQLUpgradeRestore.ps1 `
    -SqlInstance 'SRV-SQL01\SQL2022' `
    -BackupSetPath 'D:\Upgrade_Backup\2024-01-15_143022_MSSQLSERVER' `
    -SqlCredential $cred
```

### Parameters: Separate SSAS server

```powershell
.\Start-SQLUpgradeRestore.ps1 `
    -SqlInstance localhost `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER' `
    -SSASServer 'ANALYSIS-SERVER'

# If SSAS runs on a different server
```

### Full parameter list

| Parameter | Default | Description |
|-----------|---------|--------------|
| `-SqlInstance` | (required) | New SQL Server instance |
| `-BackupSetPath` | (required) | Path to the backup directory |
| `-SqlCredential` | (Windows auth) | SQL login credentials |
| `-SSASServer` | (same as SqlInstance) | Separate SSAS server |
| `-SSRSReportServerDB` | `ReportServer` | SSRS database name |
| `-Verbose` | (optional) | Detailed output |

---

## Backup Directory Structure

After a successful backup, the directory structure looks like this:

```
C:\SQLUpgrade_Backup\
+-- 2024-01-15_143022_MSSQLSERVER\
    |
    +-- Logins\
    |   +-- Logins_Export.sql           (dbatools export with password hashes)
    |   +-- Logins_Manual.sql           (fallback: manual T-SQL)
    |   +-- Logins_Inventar.csv         (overview of all logins)
    |
    +-- LinkedServers\
    |   +-- LinkedServers.sql           (CREATE + sp_addlinkedsrvlogin)
    |   +-- LinkedServers_Inventar.csv
    |   +-- LinkedServers_Logins_Inventar.csv
    |
    +-- SSIS_Legacy\
    |   +-- DTSX\                       (folder structure with .dtsx files)
    |   |   +-- Package1.dtsx
    |   |   +-- Package2.dtsx
    |   |   +-- ...
    |   +-- SSIS_Legacy_Restore.sql     (T-SQL INSERT for msdb)
    |   +-- SSIS_Legacy_Inventar.csv
    |
    +-- SSIS_Catalog\
    |   +-- SSISDB.bak                  (full database backup)
    |   +-- SSISDB_Backup_Info.txt      (backup path and restore instructions)
    |   +-- SSISDB_Inventar_Folders.csv
    |   +-- SSISDB_Inventar_Projects.csv
    |   +-- SSISDB_Inventar_Packages.csv
    |   +-- SSISDB_Inventar_Environments.csv
    |   +-- SSISDB_Inventar_EnvironmentVariables.csv
    |
    +-- SSRS\
    |   +-- Content\                    (report files with folder structure)
    |   |   +-- Finance\
    |   |   |   +-- Report1.rdl
    |   |   |   +-- Report2.rdl
    |   |   +-- Sales\
    |   |   |   +-- ...
    |   |   +-- ...
    |   +-- Config\                     (configuration files)
    |   |   +-- rsreportserver.config
    |   |   +-- rssrvpolicy.config
    |   |   +-- ...
    |   +-- SSRS_Subscriptions_Inventar.csv
    |   +-- SSRS_Rollen_Berechtigungen.csv
    |   +-- SSRS_Catalog_Inventar.csv
    |
    +-- SSAS\
    |   +-- Cube1.abf                   (SSAS backup files)
    |   +-- Cube2.abf
    |   +-- Cube1_Definition.xmla       (XMLA definitions for documentation)
    |   +-- Cube2_Definition.xmla
    |   +-- SSAS_Backup_Inventar.csv
    |   +-- SSAS_Backup_Info.txt
    |
    +-- Dependencies\
    |   +-- Dependencies_Report.csv     (dependency analysis)
    |
    +-- Backup_Summary.json             (backup metadata: size, duration, object counts)
    |
    +-- TempDB_Paths.txt                (current tempdb physical file paths, one per line)
    |
    +-- SQLUpgrade_Report.log           (detailed log file)
```

### Key files explained

| File | Contents | Usage |
|------|----------|-------|
| **Logins_Export.sql** | SQL logins with password hashes | Direct import during restore |
| **Logins_Manual.sql** | Alternative T-SQL without password hashes | Fallback if dbatools is unavailable |
| **LinkedServers.sql** | CREATE LINKED SERVER scripts | Run manually, add passwords afterwards |
| **SSISDB.bak** | Full database backup | Restore onto the new instance |
| **SSIS_Legacy_Restore.sql** | T-SQL INSERT for legacy packages | Import into msdb of the new instance |
| **Content\\** | Report .rdl, .rds, .rsd files | Copy to SSRS (optionally scripted) |
| **SSRS_Subscriptions_Inventar.csv** | List of all SSRS subscriptions | Manual re-creation (passwords are not backed up) |
| **.abf files** | SSAS cube backups | Restore onto the new SSAS instance |
| **Backup_Summary.json** | Metadata (size, duration, object counts) | Documentation and audit |
| **TempDB_Paths.txt** | Physical paths of the old tempdb data/log files | Used by the uninstall step to remove old tempdb files that live outside the standard install directories (e.g. moved to a dedicated drive) |

---

## Frequently Asked Questions

### Q: Should I use the wizard or the standalone scripts?

**A:** Use the [guided wizard](#recommended-guided-wizard) for a manual, interactive
upgrade - it asks for every value and remembers progress across the reboot. Use the
standalone scripts directly for automation/scripting, where parameters are supplied by
another process rather than a human.

### Q: Can I cancel the backup process?

**A:** Yes, with `Ctrl+C`. Files already backed up are not removed. You can restart the backup later with the same parameters (no duplicates are created).

### Q: What are the most common backup errors?

**A:**
- **dbatools not installed**: `Install-Module dbatools`
- **No sysadmin rights**: run with a sysadmin account
- **SQL Server unreachable**: check the instance name (e.g. `localhost\MSSQLSERVER`)
- **SSISDB not present**: use `SkipSSIS`

### Q: Are passwords backed up?

**A:**
- **SQL logins**: yes, password hashes (requires sysadmin)
- **Linked server passwords**: NO - must be configured manually
- **SSISDB catalog password**: no, must be known for restore
- **SSRS subscription passwords**: no, must be re-created manually

### Q: Can I back up only certain components?

**A:** Yes, use the skip parameters:
```powershell
.\Start-SQLUpgradeBackup.ps1 -SkipSSAS -SkipSSRS
```

### Q: How long does a backup take?

**A:** Depending on database size and number of reports:
- **Small systems (< 50 GB)**: 10-30 minutes
- **Medium systems (50-500 GB)**: 30-120 minutes
- **Large systems (> 500 GB)**: 2-6 hours

### Q: Can I restore onto a different server?

**A:** Yes, you can copy the backup path to a different machine and run `Start-SQLUpgradeRestore.ps1` there. The instance name SHOULD match (but is not required).

### Q: What about encryption (Transparent Data Encryption)?

**A:** TDE is not specifically backed up. After the restore, encryption keys must be reconfigured. See the SQL Server documentation on TDE migration.

### Q: Can old SSIS packages (2016) run on SQL Server 2025?

**A:** Possibly, but with compatibility issues. Use the **Test-sqmSSISPackageCompatibility** tool to check (see the separate guide).

---

## Troubleshooting

### Problem: "dbatools module could not be loaded"

**Solution:**
```powershell
Install-Module dbatools -Scope CurrentUser -Force
```

### Problem: "Cannot connect to SQL Server"

**Solution:**
1. Check the instance name: `sqlcmd -L` (lists available instances)
2. Is SQL Server running? `Get-Service MSSQL* | Select-Object Status`
3. Is TCP/IP enabled? SQL Server Configuration Manager -> SQL Server Network Configuration

### Problem: "Logins cannot be exported (sysadmin required)"

**Solution:** the user must have sysadmin rights:
```powershell
# Check: am I sysadmin?
sqlcmd -S . -Q "SELECT IS_SRVROLEMEMBER ('sysadmin')"
# Result: 1 = sysadmin, 0 = no
```

### Problem: "SSISDB.bak too large to store"

**Solution:**
1. Change the output directory to a different drive: `-OutputBaseDir 'D:\Backup'`
2. Free up disk space
3. Use `SkipSSIS` as a workaround

### Problem: "Restore process hangs"

**Solution:**
1. Disable antivirus (can block I/O)
2. Check database server performance (CPU, RAM, disk)
3. Follow the log file live in a separate PowerShell window: `tail -f .../Restore_Report.log`

### Problem: "Linked server passwords are missing"

**This is expected behavior.** SQL Server does not allow exporting linked server passwords for security reasons.

**Solution:**
1. Open `LinkedServers_Inventar.csv`
2. For each linked server, set the password with `sp_addlinkedsrvlogin`:
```sql
EXEC sp_addlinkedsrvlogin @rmtsrvname = 'LINKED_SERVER_NAME',
    @useself = 'FALSE',
    @rmtuser = 'sa',
    @rmtpassword = 'YourPassword123'
```

### Problem: "SSRS reports cannot be displayed after restore"

**Solution:**
1. Restart the SSRS service: `Restart-Service ReportServer`
2. Check the SSRS database: run `Start-SQLUpgradeRestore.ps1` with the Verbose flag
3. Open Report Manager and check for errors: `http://localhost/Reports`

---

## Contact and Support

- **GitHub Issues**: https://github.com/JankeUwe/InplaceUpDate/issues
- **Documentation**: see README.md in the GitHub repository
- **License**: MIT (open source, free of charge)

---

**Last updated**: 2026-07-29
**Guide version**: 2.0 (added guided wizard)
**Tool version**: 1.1+
