@echo off
setlocal

set "FFMPEG_EXE=%~dp0ffmpeg\ffmpeg.exe"
if not exist "%FFMPEG_EXE%" (
    set "FFMPEG_EXE=ffmpeg.exe"
)

where /q "%FFMPEG_EXE%"
if errorlevel 1 (
    echo.
    echo FAILED: Could not find ffmpeg.exe.
    echo Use either of these setups:
    echo   1) Place ffmpeg.exe in .\ffmpeg\ next to this .bat file
    echo   2) Install ffmpeg.exe in PATH
    echo.
    pause
    exit /b 1
)

for %%F in (%*) do (
    "%FFMPEG_EXE%" -i "%%~F" -map 0:v -c:v copy -an "%%~dpnF-silent%%~xF"
)

pause