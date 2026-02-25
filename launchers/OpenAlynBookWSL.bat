@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "WORKSPACE_PATH=%~1"

if "%WORKSPACE_PATH%"=="" (
  echo Usage: OpenAlynBookWSL.bat ^<workspace-path^>
  echo Example:
  echo   OpenAlynBookWSL.bat "/home/user/projects/my-app/MyApp.code-workspace"
  echo   OpenAlynBookWSL.bat "C:\dev\my-app\MyApp.code-workspace"
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%CodexWorkspaceLauncher.ps1" -WorkspacePath "%WORKSPACE_PATH%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
