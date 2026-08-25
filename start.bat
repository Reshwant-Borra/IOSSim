@echo off
echo iOS Location Sim - Starting...
echo.

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_EVERYTHING.ps1" -Mode stable
