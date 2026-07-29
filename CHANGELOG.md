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

## [Unreleased] — 2026-05-23

### Added Start-InplaceUpDate.cmd

A starter script with step selection (Backup/Uninstall/Restore).

## [1.0] — 2026-05-18

### Initial release

SQL Server in-place upgrade tool, MIT-licensed.
