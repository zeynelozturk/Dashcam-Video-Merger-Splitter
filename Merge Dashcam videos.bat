@echo off
setlocal

rem Build the file list via shift instead of %*, since a huge drag-and-drop
rem selection expanded on one line exceeds cmd.exe's ~8191-char line limit
rem and silently closes the window before PowerShell even starts.
set "FILE_LIST=%TEMP%\MergeDashcam_FileList_%RANDOM%_%RANDOM%.txt"
if exist "%FILE_LIST%" del "%FILE_LIST%"

:parseArgs
if "%~1"=="" goto argsDone
>>"%FILE_LIST%" echo(%~1
shift /1
goto parseArgs
:argsDone

if exist "%FILE_LIST%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1" -FileListPath "%FILE_LIST%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1"
)
set "EXIT_CODE=%ERRORLEVEL%"
if exist "%FILE_LIST%" del "%FILE_LIST%"
echo.
echo PowerShell exited with code %EXIT_CODE%
echo.
exit /b %EXIT_CODE%