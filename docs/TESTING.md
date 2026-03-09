# Manual Testing Matrix

Run tests manually in your own environment.

Automated CI coverage:

- Windows: `tests/Test-Windows.ps1`
- Linux: `tests/test-linux.sh`
- macOS: `tests/test-linux.sh`

Windows automated matrix now also validates a WSL UNC project target with the current WSL-native launcher flow:

- `vsc_launcher.sh` generation for WSL-hosted targets
- `.vsc_launcher/config.env` generation (instead of Windows `runner.ps1`)
- Windows shortcut generation for WSL-hosted targets
- project-root-only workspace discovery and WSL-aware default selection

## 0) Wizard generation flow

Command:

```bat
.\tools\vsc-launcher.bat "C:\path\to\repo"
```

Expected:

- If target has one workspace file, no workspace prompt is shown and workspace is selected automatically.
- If target has no workspace file, wizard creates `<project-name>.code-workspace` and selects it automatically.
- If target has multiple workspace files, wizard asks to select one.
- If WSL is available, wizard asks only the WSL questions that are relevant for the detected target type and can auto-select/infer answers when the target path already makes them obvious.
- Wizard reuses saved defaults where possible, so some prompts may be skipped entirely on repeat runs.
- It creates/replaces one launcher file in target directory plus `.vsc_launcher` metadata.
- If `.gitignore` already exists, it updates managed `.gitignore` block.
- It writes `.vsc_launcher/rollback.manifest.json` for the latest setup so rollback can work safely.
- It writes `.vscode/settings.json` with:
  - `chatgpt.openOnStartup = true`
  - `chatgpt.runCodexInWindowsSubsystemForLinux = <selected>`
- If launch target is a workspace file, it also writes the same values into `<name>.code-workspace -> settings`.
- In local Windows mode, it creates project-scoped VS Code user data under `.vsc_launcher/vscode-user-data`.
- In Remote WSL mode, it does not create `.vsc_launcher/vscode-user-data`.
- In local Windows + Codex-in-WSL mode, it sets profile-level `chatgpt.cliExecutable` to `.vsc_launcher/codex-wsl-wrapper.sh`.
- In Remote WSL mode, it uses `.vsc_launcher/vscode-agent` as a project-scoped `VSCODE_AGENT_FOLDER` to avoid sharing a single WSL VS Code server across projects.
- For WSL-hosted targets, wizard generates `vsc_launcher.sh` plus `.vsc_launcher/config.env` and can also generate `Open <project>.lnk` in a selected location (`Project root`, `Desktop`, `Start Menu`, or `Custom path`).

## 0.1) No WSL available

Expected:

- Wizard prints that WSL is not detected.
- WSL-related questions are skipped.
- `chatgpt.runCodexInWindowsSubsystemForLinux` is written as `false`.
- If target is a WSL UNC path (`\\wsl$\...`), wizard falls back to current directory and still generates local launcher artifacts.

## 1) Windows local workspace path

Command:

```bat
.\launchers\codex-session-isolator.bat "C:\path\to\repo\My.code-workspace"
```

Expected:

- VS Code opens the workspace locally (Windows).
- `C:\path\to\repo\.codex` exists.

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
- In Remote WSL launcher logs, `RemoteWSLAgentDirLinux` points to each project's own `.vsc_launcher/vscode-agent`.
- When wizard updates an existing `.gitignore`, `.codex/config.toml` remains trackable in both tracking modes.
- When `Track Codex session history in git` is enabled, `.codex/sessions/**`, `.codex/archived_sessions/**`, `.codex/memories/**`, and `.codex/session_index.jsonl` remain trackable.

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
.\tools\vsc-launcher.bat "C:\path\to\repo" --debug
```

Expected:

- Generated `.vsc_launcher/config.json` has `"enableLoggingByDefault": true`.
- `.vsc_launcher/logs` includes launcher and wizard run logs with execution details.
- For WSL-hosted targets, the generated launcher uses `.vsc_launcher/config.env` and the launcher script itself contains the detached `code` dispatch (`setsid`/`nohup`) plus a short post-dispatch wait.

## 10.1) Extension flow logging

Steps:

1. Run `Codex Session Isolator: Setup Launcher` on a project.
2. Run `Codex Session Isolator: Reopen With Launcher`.
3. Run `Codex Session Isolator: Rollback Launcher Changes` on a project that has rollback metadata.

Expected:

- VS Code Output channel `Codex Session Isolator` shows the flow decisions and failures.
- If `.vsc_launcher/logs` exists for the target, extension operations append best-effort breadcrumbs to `extension-YYYYMMDD.log`.
- The extension log includes operation type, target scope, key outcomes, and fallback decisions without blocking the main action.
- When the target has removable `.codex` runtime data, rollback also asks whether to remove it; the default answer is `No`.

## 11) Wizard default reuse

Steps:

1. Run wizard once and choose non-default answers.
2. Run wizard again and press Enter on prompts.

Expected:

- Previous answers are reused from `.vsc_launcher/wizard.defaults.json`.

## 12) Backup safety on overwrite

Steps:

1. Run wizard once on a project target.
2. Run wizard again on the same target (with any answers).
3. Inspect backup folder:
   - `<target>\.vsc_launcher\backups\`

Expected:

- A new timestamped backup session folder exists.
- Backup session contains previous copies of managed files such as:
  - `.vscode/settings.json`

## 13) Rollback safety

Commands:

```powershell
.\tools\vsc-launcher.ps1 "C:\path\to\repo" --rollback
```

```bash
./tools/vsc-launcher.sh "/path/to/repo" --rollback
```

Expected:

- Rollback succeeds only when `.vsc_launcher/rollback.manifest.json` exists for the target.
- Generated launcher files and launcher-owned metadata are removed from the project.
- `.vscode/settings.json`, workspace settings, and the managed `.gitignore` block are cleaned surgically without removing unrelated user edits.
- If the latest setup backed up a pre-existing managed file, rollback restores that backup instead of deleting blindly.
- If the optional `.codex` cleanup is enabled, rollback preserves `.codex/config.toml` and removes the rest of `.codex/`.
- If native Trash/Recycle Bin is unavailable for a launcher-owned path or opted-in `.codex` runtime data, rollback stops by default and asks whether to continue with permanent deletion.
  - `.gitignore`
  - launcher/config files when they existed before overwrite.
