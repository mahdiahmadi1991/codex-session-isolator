# Changelog

All notable changes to this project are documented in this file.

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
  - `launchers/OpenAlynBookWSL.bat`
- Workspace-isolated `CODEX_HOME` behavior (`<workspace-dir>/.codex`).
- Usage and testing documentation.
