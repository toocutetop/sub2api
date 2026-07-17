@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\start-local.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

pause
exit /b %EXIT_CODE%
