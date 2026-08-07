@echo off
setlocal
cd /d "%~dp0"
title mp4claw

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp4claw.ps1"
echo.
pause
