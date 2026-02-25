@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "FORWARD_ARGS="
set "CSI_WIZARD_DEBUG=0"

:parse_args
if "%~1"=="" goto run
if /I "%~1"=="--debug" (
  set "CSI_WIZARD_DEBUG=1"
) else (
  set "FORWARD_ARGS=!FORWARD_ARGS! "%~1""
)
shift
goto parse_args

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%vsc-launcher.ps1"!FORWARD_ARGS!
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%

