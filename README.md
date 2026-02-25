# Codex Workspace Launcher

Codex Workspace Launcher isolates Codex state per VS Code workspace.

When launched through this tool, `CODEX_HOME` is set to:

`<workspace-directory>/.codex`

This lets each project keep its own Codex data without changing your global/default behavior.

## Highlights

- Works with Windows, WSL, Linux, and macOS.
- Supports Windows paths, Linux paths, and WSL UNC paths.
- Does not modify shell profiles or global Codex settings.
- Keeps per-workspace Codex state isolated.

## Project Structure

- `launchers/CodexWorkspaceLauncher.ps1` - Primary smart launcher for Windows.
- `launchers/OpenAlynBookWSL.bat` - Convenience wrapper around the PowerShell launcher.
- `launchers/codex-workspace-launcher.sh` - Launcher for Linux/macOS.
- `docs/USAGE.md` - Usage reference.
- `docs/TESTING.md` - Manual test matrix.

## Quick Start

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexWorkspaceLauncher.ps1 -WorkspacePath "C:\dev\my-app\MyApp.code-workspace"
```

Or with wrapper:

```bat
.\launchers\OpenAlynBookWSL.bat "C:\dev\my-app\MyApp.code-workspace"
```

### Linux/macOS

```bash
chmod +x ./launchers/codex-workspace-launcher.sh
./launchers/codex-workspace-launcher.sh /path/to/my-app/MyApp.code-workspace
```

## Documentation

- Usage: `docs/USAGE.md`
- Test scenarios: `docs/TESTING.md`
- Contribution guide: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`

## License

MIT
