@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo PowerShell exited with code %EXIT_CODE%
echo.
exit /b %EXIT_CODE%