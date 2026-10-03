@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0crawl.ps1" start
echo.
pause
