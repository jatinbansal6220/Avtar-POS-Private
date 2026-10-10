@echo off
setlocal EnableExtensions

rem The SFX extracts this script and the Flutter runtime to a temporary folder.
rem Copy the complete runtime to a stable per-user location before starting it.
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')"`) do set "LOCAL_ROOT=%%I"
if not defined LOCAL_ROOT set "LOCAL_ROOT=%USERPROFILE%\AppData\Local"
set "TARGET=%LOCAL_ROOT%\AvtarPOS"
if not exist "%TARGET%" mkdir "%TARGET%"

rem A running older release locks avtar_pos.exe and prevents an update copy.
rem This installer owns that executable name and starts the fresh copy below.
if exist "%TARGET%\avtar_pos.exe" (
  taskkill /f /im avtar_pos.exe >nul 2>&1
  timeout /t 1 /nobreak >nul
)

set "SOURCE=%~dp0"
set "SOURCE=%SOURCE:~0,-1%"
robocopy "%SOURCE%" "%TARGET%" /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP >nul
set "COPY_EXIT=%ERRORLEVEL%"
if %COPY_EXIT% GEQ 8 exit /b %COPY_EXIT%

rem Create or refresh the user's Desktop shortcut with the dedicated Avtar icon.
rem Using an explicit .ico avoids Windows retaining Flutter's old shortcut-icon cache.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=[Environment]::GetFolderPath('LocalApplicationData'); $desktop=[Environment]::GetFolderPath('Desktop'); $shell=New-Object -ComObject WScript.Shell; $link=$shell.CreateShortcut((Join-Path $desktop 'AvtarPOS.lnk')); $link.TargetPath=(Join-Path $root 'AvtarPOS\avtar_pos.exe'); $link.WorkingDirectory=(Join-Path $root 'AvtarPOS'); $link.IconLocation=(Join-Path $root 'AvtarPOS\avtar_pos.ico') + ',0'; $link.Save()"

start "" "%TARGET%\avtar_pos.exe"
exit /b 0
