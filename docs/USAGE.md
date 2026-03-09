# Usage Guide

## What this launcher does

For the launched VS Code session, it sets:

`CODEX_HOME=<target-directory>/.codex`

`<target-directory>` rules:

- If target is a folder: same folder
- If target is a file: parent folder

Launch target rules (VS Code open target):

- If folder target contains `codex-session-isolator.code-workspace`, launcher opens that workspace file.
- Otherwise, if folder target contains exactly one `*.code-workspace`, launcher opens that workspace file.
- Otherwise, launcher opens the folder target.

Outside this launcher, your default Codex behavior remains unchanged.

Validation note:

- The launcher/helper flows are currently validated by CI on Windows, Linux, and macOS, with additional manual validation on WSL-backed targets.
- Any other environment combination should be considered best-effort until it is explicitly added to the validation matrix.

Session visibility and credentials:

- Launcher sessions read/write state from project-local `.codex`.
- Previous chats from your default/global Codex home are not shown in the isolated launcher session.
- You can operate different projects with different Codex account/API-key context because each project uses its own `.codex`.

## VS Code extension

If you use the extension layer (`extension/`), run these commands from command palette:

- Primary Command Palette commands:
- `Codex Session Isolator: Setup Launcher`
- `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Rollback Launcher Changes`
- Utility commands (available for direct use but hidden from the default Command Palette list):
- `Codex Session Isolator: Open Launcher Logs`
- `Codex Session Isolator: Open Launcher Config`

Extension target scope:

- At operation start, extension asks whether to apply changes to `Current project` or `Another project`.
- If `Another project` is selected during setup, extension does not reopen/close current VS Code window and shows a completion report for the selected target.
- Rollback uses the same target-selection model and then asks only the follow-up questions that are actually needed for that target.

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
.\tools\vsc-launcher.bat "\\wsl$\Ubuntu-24.04\home\user\project"
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
./tools/vsc-launcher.sh "/path/to/project" --rollback
```

Direct wizard:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vsc-launcher-wizard.ps1 -TargetPath "C:\path\to\project"
```

Wizard outputs (Windows):

- `<target>\vsc_launcher.bat` (only executable launcher in target root)
- `<selected-location>\Open <project>.lnk` (Windows shortcut; optional for WSL-hosted targets)
- `<target>\.vsc_launcher\config.json`
- `<target>\.vsc_launcher\wizard.defaults.json`
- `<target>\.vsc_launcher\rollback.manifest.json`
- `<target>\.vsc_launcher\runner.ps1`
- `<target>\.vsc_launcher\codex-wsl-wrapper.sh` (generated only for local Windows + Codex-in-WSL mode)
- `<target>\.vsc_launcher\vscode-user-data\` (VS Code isolated process profile, local Windows mode only)
- `<target>\.vsc_launcher\logs\` (wizard logs always, launcher logs in debug/`-Log`)

Wizard behavior:

- Replaces generated launcher files if they already exist.
- Updates a managed `.gitignore` block only when `.gitignore` already exists in target folder.
- The managed `.gitignore` block always keeps `.codex/config.toml` trackable.
- If `Track Codex session history in git` is enabled, the managed `.gitignore` block also keeps `.codex/sessions/**`, `.codex/archived_sessions/**`, `.codex/memories/**`, and `.codex/session_index.jsonl` trackable.
- Creates safety backups before overwriting managed files:
  - `.vsc_launcher/backups/<timestamp-pid>/`
- Records rollback ownership metadata for the latest setup in `.vsc_launcher/rollback.manifest.json`.
- Always updates `.vscode/settings.json` with:
  - `chatgpt.runCodexInWindowsSubsystemForLinux`
  - `chatgpt.openOnStartup=true`
- If launch target is a `.code-workspace` file, it also updates the workspace `settings` block with the same values.
- Auto-selects workspace when exactly one workspace file exists in target root.
- Asks workspace selection only when more than one workspace file exists in target root.
- Creates `<project-name>.code-workspace` and uses it when no workspace file exists.
- Skips WSL-related questions automatically when WSL is unavailable.
- If target path is WSL UNC (`\\wsl$\...`) while WSL is unavailable, wizard falls back to current directory and generates local launcher/Codex settings.
- For WSL-hosted targets (WSL UNC on Windows or wizard run inside WSL), wizard can generate a Windows shortcut `Open <project>.lnk` for double-click launch.
- Shortcut location is user-selected in wizard:
  - `Project root`
  - `Desktop`
  - `Start Menu`
  - `Custom path`
- Remembers previous answers and uses them as defaults for faster wizard runs.
- When WSL-specific prompts are skipped (for example wizard running inside WSL), `wizard.defaults.json` stores `useRemoteWsl` / `codexRunInWsl` as `null` instead of forcing `false`.
- First-run defaults on Windows (when WSL is available) are context-aware:
  - local Windows path: `Launch VS Code in Remote WSL mode = No`
  - Remote WSL workspace or WSL UNC target (`\\wsl$\...`): `Launch VS Code in Remote WSL mode = Yes`
  - `Set Codex to run in WSL for this project` is prompted only when Remote WSL mode is `Yes` (default `Yes`)
  - WSL distro selection is skipped when the target path already identifies the distro (for example `\\wsl$\Ubuntu-24.04\...`); otherwise the default is the Windows default distro (`wsl --status`)
  - `Track Codex session history in git`: `No`
- Enables launcher logging only in wizard debug mode (`--debug`).
- In local Windows mode, uses a project-scoped VS Code `--user-data-dir` to avoid reusing an existing global VS Code process and to apply `CODEX_HOME` reliably.
- In Remote WSL mode, skips isolated `--user-data-dir` because WSL `code` CLI does not support it, and instead uses a project-scoped `VSCODE_AGENT_FOLDER` under `.vsc_launcher/vscode-agent` so the WSL VS Code server (and Codex child processes) stay isolated per project.
- For local Windows + Codex-in-WSL mode, automatically sets profile-scoped `chatgpt.cliExecutable` to a generated WSL wrapper so Codex app-server receives project `CODEX_HOME`.

## Rollback

Use rollback when you want to remove launcher-managed changes from the latest setup for one project.

Commands:

```powershell
.\tools\vsc-launcher.ps1 "C:\path\to\project" --rollback
```

```bash
./tools/vsc-launcher.sh "/path/to/project" --rollback
```

Rollback behavior:

- Uses `.vsc_launcher/rollback.manifest.json` from the latest setup only.
- Removes launcher-owned files and directories.
- Restores backed-up pre-setup files when safe.
- Edits `.vscode/settings.json`, workspace settings, and the managed `.gitignore` block surgically so user changes are preserved.
- In the extension flow, rollback asks whether to also remove project Codex runtime data under `.codex/` when removable entries exist there.
- If that optional cleanup is enabled, rollback preserves `.codex/config.toml` and removes the rest of `.codex/`.
- Uses native Trash/Recycle Bin when available.
- If native Trash/Recycle Bin is unavailable for a launcher-owned path or opted-in `.codex` runtime data, rollback stops by default and asks whether to continue with permanent deletion.
- If no rollback manifest exists for the target, rollback fails closed instead of guessing.

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

### Windows launcher for WSL-hosted project

Use a WSL UNC path as target:

```bat
.\tools\vsc-launcher.bat "\\wsl$\Ubuntu-24.04\home\user\my-app"
```

Recommended answers:

1. `Launch VS Code in Remote WSL mode`: `Yes`
2. `Set Codex to run in WSL for this project`: `Yes`

If you force local Windows mode on a `\\wsl$\...` target, VS Code can show `Reopen Folder in WSL` guidance. That warning is expected.

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
