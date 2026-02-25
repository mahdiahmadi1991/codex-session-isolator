# Usage Guide

## What this launcher does

For the launched VS Code session, it sets:

`CODEX_HOME=<workspace-directory>/.codex`

Outside this launcher, your default Codex behavior remains unchanged.

## Windows

### PowerShell launcher (recommended)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexWorkspaceLauncher.ps1 -WorkspacePath "<workspace-path>"
```

Examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexWorkspaceLauncher.ps1 -WorkspacePath "C:\dev\my-app\MyApp.code-workspace"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexWorkspaceLauncher.ps1 -WorkspacePath "/home/user/projects/my-app/MyApp.code-workspace"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexWorkspaceLauncher.ps1 -WorkspacePath "\\wsl.localhost\Ubuntu-24.04\home\user\projects\my-app\MyApp.code-workspace"
```

### Batch wrapper

```bat
.\launchers\OpenAlynBookWSL.bat "<workspace-path>"
```

## Linux/macOS

```bash
chmod +x ./launchers/codex-workspace-launcher.sh
./launchers/codex-workspace-launcher.sh /path/to/my-app/MyApp.code-workspace
```

## Path routing rules (Windows launcher)

- Linux-style path (`/home/...`, `/mnt/c/...`) -> run in default WSL distro
- WSL UNC path (`\\wsl.localhost\<distro>\...` or `\\wsl$\<distro>\...`) -> run in that distro
- Windows path (`C:\...`) -> run local VS Code on Windows

## Notes

- The launcher creates `.codex` next to the workspace file if missing.
- The launcher does not create symlinks to `~/.codex`.
- For WSL mode, `code` must be available in WSL PATH.
