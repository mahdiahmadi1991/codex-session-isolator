# Manual Testing Matrix

Run tests manually in your own environment.

## 1) Windows local workspace path

Command:

```bat
.\launchers\OpenAlynBookWSL.bat "C:\path\to\repo\My.code-workspace"
```

Expected:

- VS Code opens the workspace locally (Windows).
- `<workspace-dir>\.codex` exists.

## 2) Linux path routed to WSL

Command:

```bat
.\launchers\OpenAlynBookWSL.bat "/home/user/projects/my-app/My.code-workspace"
```

Expected:

- VS Code opens WSL workspace.
- In integrated terminal: `echo "$CODEX_HOME"` points to `/home/user/projects/my-app/.codex`.

## 3) WSL UNC path with explicit distro

Command:

```bat
.\launchers\OpenAlynBookWSL.bat "\\wsl.localhost\Ubuntu-24.04\home\user\projects\my-app\My.code-workspace"
```

Expected:

- Workspace opens in `Ubuntu-24.04`.
- `CODEX_HOME` uses workspace `.codex` in that distro.

## 4) Linux/macOS launcher

Command:

```bash
./launchers/codex-workspace-launcher.sh /path/to/my-app/My.code-workspace
```

Expected:

- Workspace opens locally.
- `CODEX_HOME` is workspace `.codex`.

## 5) Isolation check

Steps:

1. Launch workspace A using launcher.
2. Launch workspace B using launcher.

Expected:

- A and B each keep separate `.codex` directories.
- State does not leak between projects.

## 6) Default behavior not affected

Steps:

1. Open VS Code directly (not with launcher).

Expected:

- Launcher-specific `CODEX_HOME` behavior is not forced globally.

## 7) Invalid path

Command:

```bat
.\launchers\OpenAlynBookWSL.bat "C:\not-found\missing.code-workspace"
```

Expected:

- Clear error message: workspace file not found.
