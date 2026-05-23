@echo off
:: ============================================================
:: Start-InplaceUpDate.cmd
:: ============================================================
:: Kopiert das Tool nach C:\ProgramData\InplaceUpDate und
:: startet den gewaehlten Schritt als Administrator (UAC).
::
:: Schritte (Auswahl per Menue):
::   1 - Backup    (Start-SQLUpgradeBackup.ps1)
::   2 - Uninstall (Start-SQLUpgradeUninstall.ps1)
::   3 - Restore   (Start-SQLUpgradeRestore.ps1)
::
:: Oder direkt per Parameter:
::   Start-InplaceUpDate.cmd Backup
::   Start-InplaceUpDate.cmd Uninstall
::   Start-InplaceUpDate.cmd Restore
::
:: Warum ProgramData?
::   - Nach UAC-Elevation ist W:\ nicht mehr erreichbar
::   - AppLocker/AV-unbedenklich
:: ============================================================
setlocal EnableDelayedExpansion

set "SRCDIR=%~dp0"
set "LOCALDIR=%ProgramData%\InplaceUpDate"
set "STEP=%~1"

:: Schritt per Parameter oder Menue
if /i "%STEP%"=="Backup"    goto :do_copy
if /i "%STEP%"=="Uninstall" goto :do_copy
if /i "%STEP%"=="Restore"   goto :do_copy

echo.
echo  Start-InplaceUpDate
echo  ============================================================
echo.
echo    1 - Backup     (Logins, LinkedServer, SSIS, SSRS sichern)
echo    2 - Uninstall  (SQL Server deinstallieren)
echo    3 - Restore    (Objekte wiederherstellen)
echo.
set /p "CHOICE=  Auswahl (1/2/3): "

if "%CHOICE%"=="1" set "STEP=Backup"
if "%CHOICE%"=="2" set "STEP=Uninstall"
if "%CHOICE%"=="3" set "STEP=Restore"

if "%STEP%"=="" (
    echo  Ungueltige Auswahl.
    pause
    exit /b 1
)

:do_copy
echo.
echo  Schritt : %STEP%
echo  Quelle  : %SRCDIR%
echo  Ziel    : %LOCALDIR%
echo.

if not exist "%LOCALDIR%" (
    mkdir "%LOCALDIR%"
    if errorlevel 1 (
        echo  FEHLER: Verzeichnis konnte nicht angelegt werden: %LOCALDIR%
        pause
        exit /b 1
    )
)

xcopy /Y /Q /E "%SRCDIR%." "%LOCALDIR%\" >nul 2>&1
if errorlevel 1 (
    echo  FEHLER: Kopieren fehlgeschlagen.
    pause
    exit /b 1
)

echo  Dateien bereit - starte als Administrator ...
echo.

set "LOCALPS=%LOCALDIR%\Start-SQLUpgrade%STEP%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%LOCALPS%""' -Verb RunAs"

endlocal
