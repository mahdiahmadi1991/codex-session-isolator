# Changelog

All notable changes to this project are documented in this file.

## [0.3.1] - 2026-02-25

### Changed

- Remote WSL launcher execution now runs via a temporary UTF-8 bash script file (instead of piping script text), improving reliability on Windows PowerShell.
- Remote WSL mode no longer creates or uses `.vsc_launcher/vscode-user-data`, since WSL `code` CLI does not support `--user-data-dir`.
- Launcher logs now include explicit Remote WSL notes for easier troubleshooting.
- Documentation has been unified for local vs. Remote WSL behavior and final release readiness.

### Removed

- Legacy compatibility launchers that duplicated canonical entry points:
  - `launchers/CodexWorkspaceLauncher.ps1`
  - `launchers/codex-workspace-launcher.sh`

## [0.3.0] - 2026-02-25

### Added

- Interactive launcher wizard:
  - `tools/New-VscLauncherWizard.ps1`
  - `tools/new-vsc-launcher.bat`
- Wizard-driven generation of project-specific launchers from a target path.
- Optional launcher logging support in generated launcher.

### Changed

- Documentation updated for wizard-first setup flow.
- Git ignore handling now supports policy:
  - always ignore sensitive `.codex` content
  - optionally ignore or keep `.codex/sessions` and `.codex/archived_sessions`
- Wizard flow defaults improved:
  - auto-select single workspace
  - prompt workspace selection only for multiple workspace files
  - folder mode auto-selected when no workspace file exists
  - logging prompt removed; logging enabled only in wizard debug mode
- Generated output simplified:
  - one executable launcher file in target root (`vsc_launcher.bat` on Windows)
  - launcher metadata/config moved under hidden `.vsc_launcher/`
- WSL distro detection hardened for null-separated `wsl.exe` output on Windows.
- Wizard now skips WSL-related prompts automatically when WSL is unavailable.
- Fixed generated Windows launcher for Remote WSL mode to reliably resolve Windows paths and avoid `wslpath` conversion failures.
- Wizard now persists per-target default answers for faster subsequent runs (`.vsc_launcher/wizard.defaults.json`).
- Launcher logging is now richer (run id, config snapshot, environment info, stack trace on failure, exit code).
- Workspace setting `chatgpt.openOnStartup` is now always set to `true`.
- For workspace targets, wizard now also writes `chatgpt.runCodexInWindowsSubsystemForLinux` directly into `.code-workspace` settings to avoid scope mismatch.
- Generated launcher now starts VS Code with a project-scoped `--user-data-dir` (under `.vsc_launcher/`) so `CODEX_HOME` is applied even when another VS Code instance is already running.
- Fixed local Windows + Codex-in-WSL isolation path by generating a project-scoped WSL CLI wrapper and wiring `chatgpt.cliExecutable` in isolated profile settings.
- In Remote WSL mode, generated launcher now skips creating/using project `vscode-user-data` profile and launches via temp UTF-8 bash script execution for stable WSL invocation.

## [0.2.1] - 2026-02-25

### Added

- Dependabot configuration for GitHub Actions updates.

## [0.2.0] - 2026-02-25

### Added

- Support for launching folder targets (not only workspace files).
- Dry-run mode for launchers to validate path and `CODEX_HOME` resolution without opening VS Code.

### Changed

- Documentation updated to reflect workspace-or-folder target model.
- Project naming and messaging aligned with per-project Codex session isolation.
- Canonical launcher names aligned with the project goal:
  - `launchers/CodexSessionIsolator.ps1`
  - `launchers/codex-session-isolator.bat`
  - `launchers/codex-session-isolator.sh`

## [0.1.0] - 2026-02-25

### Added

- Initial public repository structure.
- Cross-platform launcher scripts:
  - `launchers/CodexWorkspaceLauncher.ps1`
  - `launchers/codex-workspace-launcher.sh`
- Workspace-isolated `CODEX_HOME` behavior (`<workspace-dir>/.codex`).
- Usage and testing documentation.
