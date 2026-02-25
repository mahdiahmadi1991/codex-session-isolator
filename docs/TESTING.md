# Manual Testing Matrix

Run tests manually in your own environment.

## 0) Wizard generation flow

Command:

```bat
.\tools\new-vsc-launcher.bat "C:\path\to\repo"
```

Expected:

- If target has one workspace file, no workspace prompt is shown and workspace is selected automatically.
- If target has no workspace file, folder target is selected automatically.
- If target has multiple workspace files, wizard asks to select one.
- Wizard prompts for WSL options, Codex WSL setting, and session ignore.
- It creates/replaces one launcher file in target directory plus `.vsc_launcher` metadata.
- It updates managed `.gitignore` block.
- It writes `.vscode/settings.json` with:
  - `chatgpt.openOnStartup = true`
  - `chatgpt.runCodexInWindowsSubsystemForLinux = <selected>`
- If launch target is a workspace file, it also writes the same values into `<name>.code-workspace -> settings`.
- In local Windows mode, it creates project-scoped VS Code user data under `.vsc_launcher/vscode-user-data`.
- In Remote WSL mode, it does not create `.vsc_launcher/vscode-user-data`.
- In local Windows + Codex-in-WSL mode, it sets profile-level `chatgpt.cliExecutable` to `.vsc_launcher/codex-wsl-wrapper.sh`.

## 0.1) No WSL available

Expected:

- Wizard prints that WSL is not detected.
- WSL-related questions are skipped.
- `chatgpt.runCodexInWindowsSubsystemForLinux` is written as `false`.

## 1) Windows local workspace path

Command:

```bat
.\launchers\codex-session-isolator.bat "C:\path\to\repo\My.code-workspace"
```

Expected:

- VS Code opens the workspace locally (Windows).
- `C:\path\to\repo\.codex` exists.
- `C:\path\to\repo\.vsc_launcher\vscode-user-data` exists.
- `C:\path\to\repo\.vsc_launcher\vscode-user-data\User\settings.json` contains `chatgpt.cliExecutable` pointing to the generated WSL wrapper.

## 2) Windows local folder path (no workspace file)

Command:

```bat
.\launchers\codex-session-isolator.bat "C:\path\to\repo"
```

Expected:

- VS Code opens the folder locally.
- `C:\path\to\repo\.codex` exists.

## 3) Linux path routed to WSL

Command:

```bat
.\launchers\codex-session-isolator.bat "/home/user/projects/my-app/My.code-workspace"
```

Expected:

- VS Code opens WSL target.
- In integrated terminal: `echo "$CODEX_HOME"` points to `/home/user/projects/my-app/.codex`.

## 4) WSL UNC path with explicit distro

Command:

```bat
.\launchers\codex-session-isolator.bat "\\wsl.localhost\Ubuntu-24.04\home\user\projects\my-app"
```

Expected:

- Target opens in `Ubuntu-24.04`.
- `CODEX_HOME` uses `/home/user/projects/my-app/.codex`.

## 5) Linux/macOS launcher with folder target

Commands:

```bash
./launchers/codex-session-isolator.sh /path/to/my-app/My.code-workspace
./launchers/codex-session-isolator.sh /path/to/my-app
```

Expected:

- Workspace file or folder opens locally.
- `CODEX_HOME` is resolved to `<target-dir>/.codex`.

## 6) Dry-run checks (no VS Code launch)

Commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "C:\path\to\repo" -DryRun
```

```bash
./launchers/codex-session-isolator.sh /path/to/my-app --dry-run
```

Expected:

- Output prints computed launch target and `CODEX_HOME`.
- VS Code is not launched.

## 7) Isolation check

Steps:

1. Generate launchers for project A and project B with `chatgpt.runCodexInWindowsSubsystemForLinux=true`.
2. Launch both projects at nearly the same time (open A and B with their own `vsc_launcher.bat`).
3. Trigger Codex in each VS Code window.
4. Check each project logs:
   - `<project-a>\.vsc_launcher\logs\launcher-*.log`
   - `<project-b>\.vsc_launcher\logs\launcher-*.log`
   - `<project-a>\.vsc_launcher\logs\codex-wrapper.log`
   - `<project-b>\.vsc_launcher\logs\codex-wrapper.log`

Expected:

- A and B each keep separate `.codex` directories.
- State does not leak between projects.
- In launcher logs, `CODEX_HOME` points to each project's own `.codex`.
- In wrapper logs, `CODEX_HOME_FORCED` points to each project's own `.codex`.

## 8) Default behavior not affected

Steps:

1. Open VS Code directly (not with launcher).

Expected:

- Launcher-specific `CODEX_HOME` behavior is not forced globally.

## 9) Invalid path

Command:

```bat
.\launchers\codex-session-isolator.bat "C:\not-found\missing.code-workspace"
```

Expected:

- Clear error message: path not found.

## 10) Debug mode logging default

Command:

```bat
.\tools\new-vsc-launcher.bat "C:\path\to\repo" --debug
```

Expected:

- Generated `.vsc_launcher/config.json` has `"enableLoggingByDefault": true`.
- `.vsc_launcher/logs` includes launcher and wizard run logs with execution details.

## 11) Wizard default reuse

Steps:

1. Run wizard once and choose non-default answers.
2. Run wizard again and press Enter on prompts.

Expected:

- Previous answers are reused from `.vsc_launcher/wizard.defaults.json`.
