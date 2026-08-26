@echo off
setlocal

if "%~1"=="" (
	echo Drag two or more dashcam AVI files onto this batch file.
	pause
	exit /b
)

:selectOutputFolder
echo.
echo Output folder:
echo [1] Use source folder (default)
echo [2] Choose another folder
echo.
set "OUTPUT_CHOICE="
set /p "OUTPUT_CHOICE=Select [1/2] (press Enter for 1): "

if "%OUTPUT_CHOICE%"=="" goto selectAudio
if "%OUTPUT_CHOICE%"=="1" goto selectAudio
if "%OUTPUT_CHOICE%"=="2" goto chooseOutputFolder
echo Please enter 1 or 2.
goto selectOutputFolder

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

:chooseOutputFolder
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description = 'Choose output folder'; if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $dialog.SelectedPath }"`) do set "OUTPUT_DIRECTORY=%%D"

if not defined OUTPUT_DIRECTORY (
	echo No folder selected. Using the source folder.
	goto selectAudio
)

goto selectAudio

:runMerge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MergeDashcam.ps1" -OutputDirectory "%OUTPUT_DIRECTORY%" %AUDIO_ARGUMENT% %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo PowerShell exited with code %EXIT_CODE%
echo.
exit /b %EXIT_CODE%