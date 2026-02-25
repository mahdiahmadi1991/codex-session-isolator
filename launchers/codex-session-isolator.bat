@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "TARGET_PATH=%~1"
set "OPTIONAL_ARG=%~2"

if "%TARGET_PATH%"=="" (
  echo Usage: codex-session-isolator.bat ^<workspace-or-folder-path^> [--dry-run]
  exit /b 1
)

if /I "%OPTIONAL_ARG%"=="--dry-run" set "OPTIONAL_ARG=-DryRun"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%CodexSessionIsolator.ps1" -TargetPath "%TARGET_PATH%" %OPTIONAL_ARG%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
