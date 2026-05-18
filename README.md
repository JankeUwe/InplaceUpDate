# SQL Server Inplace Upgrade Tool

PowerShell-Tool zur Sicherung, Deinstallation und Wiederherstellung von SQL Server Komponenten
vor und nach einem Inplace-Upgrade.

## Voraussetzungen

- PowerShell 5.1 oder höher
- dbatools Modul: `Install-Module dbatools`
- Sysadmin-Rechte auf der SQL Server Instanz
- Lokale Administratorrechte auf dem Server
- Für SSAS: Microsoft.AnalysisServices Assembly (wird mit SSMS oder SSAS installiert)

## Ablauf

```
1. Start-SQLUpgradeBackup.ps1   → Sicherung aller Objekte
2. Start-SQLUpgradeUninstall.ps1 → SQL Server deinstallieren
3. Neue SQL Server Version installieren (manuell)
4. Start-SQLUpgradeRestore.ps1  → Objekte wiederherstellen
```

## Skripte

### Start-SQLUpgradeBackup.ps1
Sichert alle Objekte vor der Deinstallation.

**Parameter:**
| Parameter | Standard | Beschreibung |
|-----------|----------|--------------|
| SqlInstance | localhost | SQL Server Instanz |
| OutputBaseDir | C:\SQLUpgrade_Backup | Ausgabeverzeichnis |
| InstanceName | MSSQLSERVER | Instanzname für Deinstallation |
| SSASServer | (wie SqlInstance) | Separater SSAS-Server |
| SSRSReportServerDB | ReportServer | SSRS-Datenbankname |
| SqlCredential | (Windows-Auth) | SQL-Login Credentials |
| SSISDBBackupPath | (SQL Server Default) | Pfad für SSISDB-Backup |
| SkipSSAS | $false | SSAS-Sicherung überspringen |
| SkipSSRS | $false | SSRS-Sicherung überspringen |

**Beispiel:**
```powershell
# Standardinstanz
.\Start-SQLUpgradeBackup.ps1

# Benannte Instanz mit benutzerdefiniertem Pfad
.\Start-SQLUpgradeBackup.ps1 -SqlInstance 'SRV01\SQL2019' -InstanceName 'SQL2019' -OutputBaseDir 'D:\Backup'
```

---

### Start-SQLUpgradeUninstall.ps1
Deinstalliert SQL Server nach erfolgreicher Sicherung.

**Parameter:**
| Parameter | Standard | Beschreibung |
|-----------|----------|--------------|
| InstanceName | MSSQLSERVER | Zu deinst. Instanz |
| BackupSetPath | (Pflicht) | Pfad zum Backup-Set |
| SetupPath | (automatisch) | Pfad zu setup.exe |
| Features | (alle) | Zu deinst. Features |
| SkipCleanup | $false | Verz.-Cleanup überspringen |
| NoRestart | $false | Kein automatischer Neustart |

**Beispiel:**
```powershell
.\Start-SQLUpgradeUninstall.ps1 `
    -InstanceName MSSQLSERVER `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'
```

---

### Start-SQLUpgradeRestore.ps1
Stellt alle gesicherten Objekte wieder her (interaktiv).

**Parameter:**
| Parameter | Standard | Beschreibung |
|-----------|----------|--------------|
| SqlInstance | (Pflicht) | Neue SQL Server Instanz |
| BackupSetPath | (Pflicht) | Pfad zum Backup-Set |
| SqlCredential | (Windows-Auth) | SQL-Login Credentials |
| SSASServer | (wie SqlInstance) | Separater SSAS-Server |
| SSRSReportServerDB | ReportServer | SSRS-Datenbankname |

**Beispiel:**
```powershell
.\Start-SQLUpgradeRestore.ps1 `
    -SqlInstance localhost `
    -BackupSetPath 'C:\SQLUpgrade_Backup\2024-01-15_143022_MSSQLSERVER'
```

---

## Ausgabestruktur

```
C:\SQLUpgrade_Backup\
└── YYYY-MM-DD_HHMMSS_INSTANZNAME\
    ├── Logins\
    │   ├── Logins_Export.sql           (dbatools Export inkl. Passwort-Hashes)
    │   ├── Logins_Manual.sql           (manuell generiertes T-SQL, Fallback)
    │   └── Logins_Inventar.csv
    ├── LinkedServers\
    │   ├── LinkedServers.sql           (T-SQL CREATE + sp_addlinkedsrvlogin)
    │   ├── LinkedServers_Inventar.csv
    │   └── LinkedServers_Logins_Inventar.csv
    ├── SSIS_Legacy\
    │   ├── DTSX\                       (Ordnerstruktur mit .dtsx Dateien)
    │   ├── SSIS_Legacy_Restore.sql     (T-SQL INSERT für msdb)
    │   └── SSIS_Legacy_Inventar.csv
    ├── SSIS_Catalog\
    │   ├── SSISDB_Backup_Info.txt      (Backup-Pfad + Restore-Anleitung)
    │   ├── SSISDB_Inventar_Folders.csv
    │   ├── SSISDB_Inventar_Projects.csv
    │   ├── SSISDB_Inventar_Packages.csv
    │   ├── SSISDB_Inventar_Environments.csv
    │   └── SSISDB_Inventar_EnvironmentVariables.csv
    ├── SSRS\
    │   ├── Content\                    (.rdl, .rds, .rsd Dateien, Ordnerstruktur)
    │   ├── Config\                     (rsreportserver.config, rssrvpolicy.config, ...)
    │   ├── SSRS_Subscriptions_Inventar.csv
    │   ├── SSRS_Rollen_Berechtigungen.csv
    │   └── SSRS_Catalog_Inventar.csv
    ├── SSAS\
    │   ├── *.abf                       (SSAS Backup-Dateien, auf SQL Server)
    │   ├── *_Definition.xmla          (XMLA Definitionen zur Dokumentation)
    │   ├── SSAS_Backup_Inventar.csv
    │   └── SSAS_Backup_Info.txt
    ├── Dependencies\
    │   └── Dependencies_Report.csv
    ├── Backup_Summary.json
    └── SQLUpgrade_Report.log
```

---

## Hinweise

### Passwörter
- **SQL Logins**: Passwort-Hashes werden gesichert (erfordert sysadmin)
- **Linked Server Passwörter**: Können von SQL Server **nicht** exportiert werden → müssen nach der Wiederherstellung manuell gesetzt werden
- **SSISDB Catalog-Passwort**: Muss bekannt sein für Restore
- **SSAS Backup-Passwort**: Falls beim Backup gesetzt, für Restore erforderlich

### Verschlüsselte SSIS-Pakete
Pakete mit `ProtectionLevel = EncryptSensitiveWithPassword` oder `EncryptAllWithPassword`
benötigen das Original-Passwort für die Wiederherstellung.

### SSRS Subscriptions
Subscription-Passwörter für Delivery-Konten werden nicht exportiert.
Das Inventar (`SSRS_Subscriptions_Inventar.csv`) dokumentiert alle Subscriptions
zur manuellen Neuerstellung.

### SSAS auf getrenntem Server
Falls SSAS auf einem anderen Server läuft, `-SSASServer` entsprechend setzen.
Die .abf-Backup-Dateien liegen im BackupDir des SSAS-Servers, nicht im Ausgabeverzeichnis.
