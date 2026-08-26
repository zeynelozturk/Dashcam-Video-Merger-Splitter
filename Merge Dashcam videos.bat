@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1" %*
echo.
echo PowerShell exited with code %ERRORLEVEL%
echo.
pause