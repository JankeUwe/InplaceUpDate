# InplaceUpDate / SQLUpgrade-Tool — Changelog

## [Unreleased] — 2026-07-29

### Added geführter Wizard

`Start-SQLUpgradeWizard.ps1` führt interaktiv durch Sicherung, Deinstallation und
Wiederherstellung, fragt alle Werte mit Standardwerten/Validierung ab und merkt
sich den Fortschritt über den Neustart zwischen Deinstallation und manueller
Neuinstallation hinweg (`Modules\Common\Wizard-UI.ps1`, `Modules\Common\WizardState.ps1`).
`Start-InplaceUpDate.cmd` bietet den Wizard jetzt als Standardoption `0` an.

## [Unreleased] — 2026-05-23

### Added Start-InplaceUpDate.cmd

A starter script with step selection (Backup/Uninstall/Restore).

## [1.0] — 2026-05-18

### Initial release

SQL Server in-place upgrade tool, MIT-licensed.
