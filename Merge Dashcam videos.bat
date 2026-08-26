@echo off
setlocal

if "%~1"=="" (
	echo Drag two or more dashcam AVI files onto this batch file.
	pause
	exit /b
)

:selectAudio
echo.
set "AUDIO_CHOICE="
set "AUDIO_ARGUMENT="
set /p "AUDIO_CHOICE=Include audio? (Y/n, press Enter for Y): "

if "%AUDIO_CHOICE%"=="" goto runMerge
if /I "%AUDIO_CHOICE%"=="Y" goto runMerge
if /I "%AUDIO_CHOICE%"=="N" set "AUDIO_ARGUMENT=-ExcludeAudio"
if /I "%AUDIO_CHOICE%"=="N" goto runMerge
echo Please enter Y or N.
goto selectAudio

:runMerge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1" %AUDIO_ARGUMENT% %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo PowerShell exited with code %EXIT_CODE%
echo.
exit /b %EXIT_CODE%