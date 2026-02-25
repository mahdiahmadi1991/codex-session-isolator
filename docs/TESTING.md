# Manual Testing Matrix

Run tests manually in your own environment.

## 0) Wizard generation flow

Command:

```bat
.\tools\new-vsc-launcher.bat "C:\path\to\repo"
```

Expected:

- Wizard prompts for launch mode, WSL options, Codex WSL setting, session ignore, and logging.
- It creates/replaces launcher files in target directory.
- It updates managed `.gitignore` block.

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

1. Launch project A using launcher.
2. Launch project B using launcher.

Expected:

- A and B each keep separate `.codex` directories.
- State does not leak between projects.

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
