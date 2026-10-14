@echo off
setlocal
title Avtar POS Localhost
echo Starting Avtar POS localhost. Please keep the extracted folders together.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_localhost.ps1"
if errorlevel 1 pause
