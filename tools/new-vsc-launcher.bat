@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "TARGET_PATH="
set "DEBUG_ARG="

:parse_args
if "%~1"=="" goto run
if /I "%~1"=="--debug" (
  set "DEBUG_ARG=-DebugMode"
) else (
  if not defined TARGET_PATH set "TARGET_PATH=%~1"
)
shift
goto parse_args

:run
if defined TARGET_PATH (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%New-VscLauncherWizard.ps1" -TargetPath "%TARGET_PATH%" %DEBUG_ARG%
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%New-VscLauncherWizard.ps1" %DEBUG_ARG%
)

set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
