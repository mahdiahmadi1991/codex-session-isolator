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
- `tools/vsc-launcher.ps1` - Cross-platform wizard helper core.
- `tools/vsc-launcher.bat` - Wizard helper entrypoint for Windows.
- `tools/vsc-launcher.sh` - Wizard helper entrypoint for Linux/macOS.
- `tests/Test-Windows.ps1` - End-to-end Windows integration tests.
- `tests/test-linux.sh` - End-to-end Unix integration tests (Linux and macOS).
- `docs/USAGE.md` - Usage reference (workspace or folder target).
- `docs/TESTING.md` - Manual test matrix.

## Quick Start

### Wizard helper (recommended)

Windows (CMD):

```bat
.\tools\vsc-launcher.bat "C:\path\to\project"
.\tools\vsc-launcher.bat "C:\path\to\project" --debug
```

Windows (PowerShell):

```powershell
.\tools\vsc-launcher.ps1 "C:\path\to\project"
.\tools\vsc-launcher.ps1 "C:\path\to\project" --debug
```

Linux/macOS:

```bash
chmod +x ./tools/vsc-launcher.sh
./tools/vsc-launcher.sh "/path/to/project"
./tools/vsc-launcher.sh "/path/to/project" --debug
```

Helper options:

- `--help` show usage
- `--debug` generate launcher with logging enabled by default
- `--target <path>` pass target explicitly

Direct wizard (advanced):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vsc-launcher-wizard.ps1 -TargetPath "C:\path\to\project"
```

The wizard asks for:

- Remote WSL mode
- whether Codex should run in WSL for this project
- whether Codex chat sessions should be git-ignored

Wizard defaults:

- If exactly one workspace file exists in target path, it is selected automatically.
- If no workspace file exists, folder target is used.
- It asks workspace selection only when more than one workspace file is found.
- If WSL is not installed/available, WSL-related questions are skipped automatically.
- Wizard remembers your previous answers per target (`.vsc_launcher/wizard.defaults.json`) and reuses them as defaults.
- Logging is disabled by default and enabled only when running wizard with `--debug`.
- On Windows, it generates one executable launcher file in target root (`vsc_launcher.bat`) and stores metadata in `.vsc_launcher/`.
- Wizard always writes:
  - `chatgpt.openOnStartup=true`
  - `chatgpt.runCodexInWindowsSubsystemForLinux=<selected>`
  in `.vscode/settings.json`, and also in `.code-workspace` settings when launch target is a workspace file.
- In local Windows mode, generated launcher runs VS Code with a project-scoped `--user-data-dir` under `.vsc_launcher/` to ensure `CODEX_HOME` is applied reliably.
- In Remote WSL mode, launcher skips isolated `--user-data-dir` because WSL `code` CLI does not support that option.
- When `chatgpt.runCodexInWindowsSubsystemForLinux=true` and launch mode is local Windows, launcher configures an isolated `chatgpt.cliExecutable` wrapper in the project profile to force project `CODEX_HOME` for Codex app-server.

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
- Release steps: `docs/RELEASE.md`
- Contribution guide: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`

## License

MIT


