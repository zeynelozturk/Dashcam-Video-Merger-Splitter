@echo off
for %%F in (%*) do (
    ffmpeg -i "%%~F" -map 0:v -c:v copy -an "%%~dpnF-silent%%~xF"
)
pause