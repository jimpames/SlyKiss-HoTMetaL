@echo off
title CLI-Browser
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CLI-Browser.ps1" %*
pause
