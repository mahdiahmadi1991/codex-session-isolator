# Usage Guide

## What this launcher does

For the launched VS Code session, it sets:

`CODEX_HOME=<target-directory>/.codex`

`<target-directory>` rules:

- If target is a folder: same folder
- If target is a file: parent folder

Outside this launcher, your default Codex behavior remains unchanged.

## Launcher wizard (recommended)

Use the wizard to generate a project-specific launcher in your target folder.

Windows (batch entrypoint):

```bat
.\tools\new-vsc-launcher.bat "C:\path\to\project"
```

PowerShell direct:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-VscLauncherWizard.ps1 -TargetPath "C:\path\to\project"
```

Wizard outputs (Windows):

- `<target>\vsc_launcher.ps1`
- `<target>\vsc_launcher.bat`
- `<target>\vsc_launcher.config.json`

Wizard behavior:

- Replaces generated launcher files if they already exist.
- Updates a managed `.gitignore` block in target folder.
- Updates `.vscode/settings.json` for `chatgpt.runCodexInWindowsSubsystemForLinux`.

## Windows

### PowerShell launcher (recommended)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "<workspace-or-folder-path>"
```

Examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "C:\dev\my-app\MyApp.code-workspace"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "C:\dev\my-app"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "/home/user/projects/my-app/MyApp.code-workspace"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "\\wsl.localhost\Ubuntu-24.04\home\user\projects\my-app"
```

### Batch wrapper

```bat
.\launchers\codex-session-isolator.bat "<workspace-or-folder-path>" [--dry-run]
```

## Linux/macOS

```bash
chmod +x ./launchers/codex-session-isolator.sh
./launchers/codex-session-isolator.sh /path/to/my-app/MyApp.code-workspace
./launchers/codex-session-isolator.sh /path/to/my-app
./launchers/codex-session-isolator.sh /path/to/my-app --dry-run
```

## Path routing rules (Windows launcher)

- Linux-style path (`/home/...`, `/mnt/c/...`) -> run in default WSL distro
- WSL UNC path (`\\wsl.localhost\<distro>\...` or `\\wsl$\<distro>\...`) -> run in that distro
- Windows path (`C:\...`) -> run local VS Code on Windows

## Notes

- The launcher creates `.codex` inside the target directory if missing.
- The launcher does not create symlinks to `~/.codex`.
- For WSL mode, `code` must be available in WSL PATH.
