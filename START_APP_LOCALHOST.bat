@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules;%ProgramFiles%\WindowsPowerShell\Modules"
title Avtar POS Localhost
echo Starting Avtar POS localhost. Please keep the extracted folders together.
set "AVTAR_LAUNCH_ROOT=%~dp0"
if not exist "%~dp0tools\start_localhost.ps1" (
    echo First run: preparing the localhost launcher. Internet is required once.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $dir=Join-Path $env:AVTAR_LAUNCH_ROOT 'tools'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; Invoke-WebRequest 'https://raw.githubusercontent.com/jatinbansal6220/Avtar-POS-Private/main/tools/start_localhost.ps1' -OutFile (Join-Path $dir 'start_localhost.ps1') -UseBasicParsing"
    if errorlevel 1 (
        pause
        exit /b 1
    )
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_localhost.ps1" %*
if errorlevel 1 pause
