# Codex Session Isolator

[![CI](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/ci.yml/badge.svg)](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mahdiahmadi1991/codex-session-isolator)](https://github.com/mahdiahmadi1991/codex-session-isolator/releases)
[![License](https://img.shields.io/github/license/mahdiahmadi1991/codex-session-isolator)](LICENSE)

Codex Session Isolator gives each code environment its own Codex session state.

When launched through this tool, `CODEX_HOME` is set to:

`<target-directory>/.codex`

`<target-directory>` is:

- the workspace directory (if target is a `.code-workspace` file)
- the folder itself (if target is a directory)
- the parent directory (if target is any file)

This isolates Codex state per project without changing global/default behavior.

## Highlights

- Works with Windows, WSL, Linux, and macOS.
- Supports Windows paths, Linux paths, and WSL UNC paths.
- Does not modify shell profiles or global Codex settings.
- Keeps per-project Codex state isolated.
- Supports both workspace files and plain folders (no workspace required).
- Includes an interactive launcher wizard for generating project-specific launchers.

## Project Structure

- `launchers/CodexSessionIsolator.ps1` - Primary smart launcher for Windows.
- `launchers/codex-session-isolator.bat` - Canonical batch launcher for Windows.
- `launchers/codex-session-isolator.sh` - Canonical launcher for Linux/macOS.
- `launchers/OpenAlynBookWSL.bat` - Compatibility wrapper.
- `docs/USAGE.md` - Usage reference (workspace or folder target).
- `docs/TESTING.md` - Manual test matrix.

## Quick Start

### Generate a launcher (wizard)

Windows:

```bat
.\tools\new-vsc-launcher.bat "C:\path\to\project"
```

PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-VscLauncherWizard.ps1 -TargetPath "C:\path\to\project"
```

The wizard asks for:

- folder vs workspace launch target
- Remote WSL mode and distro selection (when needed)
- whether Codex should run in WSL for this project
- whether `.codex/sessions` and `.codex/archived_sessions` should be git-ignored
- optional logging default for the generated launcher

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "C:\dev\my-app\MyApp.code-workspace"
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "C:\dev\my-app"
```

Or with wrapper:

```bat
.\launchers\codex-session-isolator.bat "C:\dev\my-app\MyApp.code-workspace"
.\launchers\codex-session-isolator.bat "C:\dev\my-app"
```

### Linux/macOS

```bash
chmod +x ./launchers/codex-session-isolator.sh
./launchers/codex-session-isolator.sh /path/to/my-app/MyApp.code-workspace
./launchers/codex-session-isolator.sh /path/to/my-app
```

## Documentation

- Usage: `docs/USAGE.md`
- Test scenarios: `docs/TESTING.md`
- Contribution guide: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`

## License

MIT
