@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Prepare-Release.ps1"

if not exist "%PS1%" (
    echo Missing script: "%PS1%"
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
    echo.
    echo Release preparation failed.
    echo.
    pause
    exit /b 1
)

exit /b 0
