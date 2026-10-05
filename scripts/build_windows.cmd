@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1"
set "build_exit_code=%ERRORLEVEL%"

echo.
if not "%build_exit_code%"=="0" echo Build failed with exit code %build_exit_code%.
pause
exit /b %build_exit_code%
