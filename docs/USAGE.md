# Usage Guide

## What this launcher does

For the launched VS Code session, it sets:

`CODEX_HOME=<target-directory>/.codex`

`<target-directory>` rules:

- If target is a folder: same folder
- If target is a file: parent folder

Outside this launcher, your default Codex behavior remains unchanged.

Session visibility and credentials:

- Launcher sessions read/write state from project-local `.codex`.
- Previous chats from your default/global Codex home are not shown in the isolated launcher session.
- You can operate different projects with different Codex account/API-key context because each project uses its own `.codex`.

## VS Code extension (preview)

If you use the extension layer (`extension/`), run these commands from command palette:

- `Codex Session Isolator: Initialize Launcher`
- `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Open Launcher Logs`
- `Codex Session Isolator: Open Launcher Config`

Dev setup:

```bash
cd extension
npm install
npm run compile
```

## Launcher wizard (recommended)

Use the wizard to generate a project-specific launcher in your target folder.

Windows (batch entrypoint):

```bat
.\tools\vsc-launcher.bat "C:\path\to\project"
.\tools\vsc-launcher.bat "C:\path\to\project" --debug
```

Windows (PowerShell helper):

```powershell
.\tools\vsc-launcher.ps1 "C:\path\to\project"
.\tools\vsc-launcher.ps1 "C:\path\to\project" --debug
```

Linux/macOS (helper):

```bash
chmod +x ./tools/vsc-launcher.sh
./tools/vsc-launcher.sh "/path/to/project"
./tools/vsc-launcher.sh "/path/to/project" --debug
```

Direct wizard:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vsc-launcher-wizard.ps1 -TargetPath "C:\path\to\project"
```

Wizard outputs (Windows):

- `<target>\vsc_launcher.bat` (only executable launcher in target root)
- `<target>\.vsc_launcher\config.json`
- `<target>\.vsc_launcher\wizard.defaults.json`
- `<target>\.vsc_launcher\runner.ps1`
- `<target>\.vsc_launcher\codex-wsl-wrapper.sh` (generated only for local Windows + Codex-in-WSL mode)
- `<target>\.vsc_launcher\vscode-user-data\` (VS Code isolated process profile, local Windows mode only)
- `<target>\.vsc_launcher\logs\` (wizard logs always, launcher logs in debug/`-Log`)

Wizard behavior:

- Replaces generated launcher files if they already exist.
- Updates a managed `.gitignore` block in target folder.
- Creates safety backups before overwriting managed files:
  - `.vsc_launcher/backups/<timestamp-pid>/`
- Always updates `.vscode/settings.json` with:
  - `chatgpt.runCodexInWindowsSubsystemForLinux`
  - `chatgpt.openOnStartup=true`
- If launch target is a `.code-workspace` file, it also updates the workspace `settings` block with the same values.
- Auto-selects workspace when exactly one workspace file exists.
- Asks workspace selection only when more than one workspace file exists.
- Uses folder target automatically when no workspace file exists.
- Skips WSL-related questions automatically when WSL is unavailable.
- Remembers previous answers and uses them as defaults for faster wizard runs.
- Enables launcher logging only in wizard debug mode (`--debug`).
- In local Windows mode, uses a project-scoped VS Code `--user-data-dir` to avoid reusing an existing global VS Code process and to apply `CODEX_HOME` reliably.
- In Remote WSL mode, skips isolated `--user-data-dir` because WSL `code` CLI does not support it.
- For local Windows + Codex-in-WSL mode, automatically sets profile-scoped `chatgpt.cliExecutable` to a generated WSL wrapper so Codex app-server receives project `CODEX_HOME`.

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
