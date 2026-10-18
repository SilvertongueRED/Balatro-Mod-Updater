@echo off
REM Use this if Balatro won't start right after the Mod Updater updated your mods.
REM It lists the mods from the last update and asks what to do:
REM   Enter  = put back the previous version of ALL of them
REM   1,3    = put back only those numbers
REM   K      = keep everything as it is
REM Put-back mods are pinned (they won't update again until you unpin them in the Mod Updater settings).
REM Close Balatro first.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autoupdate.ps1" -ModsDir "%~dp0.." -SelfDir "%~dp0." -RollbackRecent -Interactive
echo.
echo Done. Details are in last_run.json. You can start Balatro again.
pause
