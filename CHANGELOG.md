# InplaceUpDate / SQLUpgrade-Tool — Changelog

## [Unreleased] — 2026-07-29

### Added geführter Wizard

`Start-SQLUpgradeWizard.ps1` führt interaktiv durch Sicherung, Deinstallation und
Wiederherstellung, fragt alle Werte mit Standardwerten/Validierung ab und merkt
sich den Fortschritt über den Neustart zwischen Deinstallation und manueller
Neuinstallation hinweg (`Modules\Common\Wizard-UI.ps1`, `Modules\Common\WizardState.ps1`).
`Start-InplaceUpDate.cmd` bietet den Wizard jetzt als Standardoption `0` an.

### Added Docs/SQL_Server_Upgrade_Guide.md

Ausführliches Benutzerhandbuch (Englisch), ersetzt den bisherigen deutschen
Runbook-Entwurf; um den Wizard-Abschnitt ergänzt und nach `Docs/` verschoben.

### Fixed Set-StrictMode-Abstürze bei fehlenden Properties

Punkt-Zugriff auf dynamisch benannte oder nicht garantierte Properties
(`$instProps.$InstanceName` in `Invoke-SQLUninstall.ps1`, `$val.Status`/`.CanProceed`
in der Backup-Zusammenfassung) warf unter `Set-StrictMode -Version Latest` einen
Fehler statt `$null` zu liefern, sobald die Property nicht existierte - z.B. wenn die
angegebene Instanz nicht installiert ist, oder bei der Dependencies-Zusammenfassung.
Das brach den Wizard/die Skripte sofort ab. Ersetzt durch
`Select-Object -ExpandProperty ... -ErrorAction SilentlyContinue`.

### Fixed Konsolen-Schmierzeichen (Umlaute)

`[Console]::OutputEncoding` wird jetzt in allen vier Einstiegsskripten auf UTF-8
gesetzt. Vorher passte die PowerShell-5.1-Standard-Codepage nicht zur
UTF-8-Kodierung der Skriptdateien, wodurch Umlaute (ü, ä, ö, ß) in der
Konsolenausgabe als Schmierzeichen erschienen.

### Added TempDB-Erfassung und -Bereinigung

`Start-SQLUpgradeBackup.ps1` erfasst jetzt (Schritt 8) die aktuellen TempDB-Dateipfade
per `Get-DbaDbFile` und speichert sie in `TempDB_Paths.txt`. Beim Verzeichnis-Cleanup
in `Invoke-SQLUninstall.ps1` werden diese Dateien gezielt zusätzlich entfernt - relevant
wenn TempDB per `ALTER DATABASE tempdb MODIFY FILE` auf ein eigenes Laufwerk verschoben
wurde und dadurch außerhalb der üblichen Installationsverzeichnisse liegt.

### Changed Start-InplaceUpDate.cmd: -NoExit

Das elevierte PowerShell-Fenster bleibt nach Skriptende jetzt offen (`-NoExit`),
statt sich bei einem Fehler sofort zu schließen, bevor die Fehlermeldung lesbar war.

## [Unreleased] — 2026-05-23

### Added Start-InplaceUpDate.cmd

A starter script with step selection (Backup/Uninstall/Restore).

## [1.0] — 2026-05-18

### Initial release

SQL Server in-place upgrade tool, MIT-licensed.
