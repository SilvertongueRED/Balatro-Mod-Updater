@echo off
REM Use this if Balatro won't start right after the Mod Updater updated your mods.
REM It puts back the previous version of every mod from the last update and pins them
REM (so they won't update again until you unpin them in the Mod Updater settings).
REM Close Balatro first.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autoupdate.ps1" -ModsDir "%~dp0.." -SelfDir "%~dp0." -RollbackRecent
echo.
echo Done. Details are in last_run.json. You can start Balatro again.
pause
