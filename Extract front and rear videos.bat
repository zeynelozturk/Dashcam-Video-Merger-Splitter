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

if "%~1"=="" (
    echo Drag one or more dashcam AVI files onto this batch file.
    pause
    exit /b
)

:process
echo.
echo Processing: %~nx1

"%FFMPEG_EXE%" -i "%~1" -map 0:v:0 -map 0:a:0 -c copy "%~dpn1_front.avi"
"%FFMPEG_EXE%" -i "%~1" -map 0:v:1 -map 0:a:0 -c copy "%~dpn1_rear.avi"

powershell -NoProfile -Command "$src = Get-Item -LiteralPath '%~1'; $front = Get-Item -LiteralPath '%~dpn1_front.avi'; $rear = Get-Item -LiteralPath '%~dpn1_rear.avi'; $front.CreationTime = $src.CreationTime; $front.LastWriteTime = $src.LastWriteTime; $rear.CreationTime = $src.CreationTime; $rear.LastWriteTime = $src.LastWriteTime"

shift
if not "%~1"=="" goto process

echo.
echo All files processed.
pause