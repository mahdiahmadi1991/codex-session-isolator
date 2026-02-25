# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- New VS Code extension workspace (`extension/`) as a hybrid UX layer over launcher backend.
- Auto-merge workflow for safe PRs (`.github/workflows/auto-merge-safe-prs.yml`) with branch and file-scope safeguards.
- Main promotion policy workflow (`.github/workflows/main-promotion-policy.yml`) to require `pre-release` as the source branch for PRs into `main` (with explicit hotfix override label).
- Stable release notes template (`docs/RELEASE_TEMPLATE.md`).
- AI agent onboarding guide (`AGENTS.md`) with project map, guardrails, and validation checklist.
- GitHub AI instruction file (`.github/instructions/repo.instructions.md`) for faster, consistent agent onboarding in PR workflows.
- Repository workspace file (`codex-session-isolator.code-workspace`) with recommended settings and extensions.
- Extension commands to initialize launcher, reopen with launcher, and open launcher logs/config.
- Extension documentation: `docs/EXTENSION.md`.
- Marketplace preparation guide: `docs/MARKETPLACE.md`.
- Extension Marketplace assets: `extension/media/icon.png` and `extension/media/hero.png`.
- Marketplace publish automation workflow: `.github/workflows/extension-publish.yml` (release/manual plus optional auto pre-release on `main`).
- Extension build/package flow now auto-syncs bundled wizard from `tools/vsc-launcher-wizard.ps1` via `extension/scripts/sync-wizard.mjs`.
- Privacy notice: `PRIVACY.md`.
- Trust and safety model guide: `docs/TRUST.md`.
- Dedicated security workflow: `.github/workflows/security.yml` (dependency review, secret scan, PowerShell syntax validation, npm audit, CodeQL).

### Changed

- README and usage docs now include extension-based workflow.
- CI and Security workflows are now scoped to `main` and `pre-release` branches only (push and pull request events).
- Marketplace publish workflow now auto-publishes pre-release builds from `pre-release` branch pushes (stable publish remains release-driven).
- Extension metadata and README content were enriched for Marketplace readiness.
- Extension identifier namespace was refined to `codexSessionIsolator` and package id to `codex-session-isolator`.
- Extension publisher id for Marketplace packaging was updated to `2ma`.
- Marketplace hero image was regenerated at larger dimensions to prevent text clipping.
- Wizard now creates safety backups before overwriting managed files under `.vsc_launcher/backups/<timestamp-pid>/`.
- Extension now enforces trusted workspace and asks explicit confirmation before launcher initialization (default enabled).
- Marketplace publish workflow now packages VSIX once, publishes from `--packagePath`, and produces SHA-256 checksum artifacts (attached on stable releases).
- Windows integration tests now validate backup creation for wizard overwrites.
- Documentation now explicitly clarifies project-isolated chat visibility and per-project account/API-key context.

## [0.3.2] - 2026-02-25

### Changed

- Windows test suite now validates `--target` argument error handling and generated-wizard flow through `--target` for better helper coverage.
- Manual testing guide was corrected to match canonical launcher behavior and conditional WSL prompts.
- README now clarifies direct wizard PowerShell requirement.
- Added a project banner image to README for clearer project branding.
- Wizard path normalization now resolves canonical paths before computing relative workspace paths, avoiding short/long Windows path mismatches.
- Unix integration tests now enforce execute permission on `tools/vsc-launcher.sh` in CI before running helper checks.

## [0.3.1] - 2026-02-25

### Changed

- Added a stronger cross-platform wizard helper (`tools/vsc-launcher.ps1`) with Windows/Linux/macOS entrypoints and consistent argument handling (`--help`, `--debug`, `--target`).
- Remote WSL launcher execution now runs via a temporary UTF-8 bash script file (instead of piping script text), improving reliability on Windows PowerShell.
- Remote WSL mode no longer creates or uses `.vsc_launcher/vscode-user-data`, since WSL `code` CLI does not support `--user-data-dir`.
- Launcher logs now include explicit Remote WSL notes for easier troubleshooting.
- Documentation has been unified for local vs. Remote WSL behavior and final release readiness.
- CI now runs comprehensive automated integration tests for Windows (`tests/Test-Windows.ps1`) and Linux (`tests/test-linux.sh`).
- CI macOS coverage was added using the same Unix integration suite (`tests/test-linux.sh`).

### Removed

- Legacy compatibility launchers that duplicated canonical entry points:
  - `launchers/CodexWorkspaceLauncher.ps1`
  - `launchers/codex-workspace-launcher.sh`

## [0.3.0] - 2026-02-25

### Added

- Interactive launcher wizard:
  - `tools/vsc-launcher-wizard.ps1`
  - `tools/vsc-launcher.bat`
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
  - launcher metadata/config moved under `.vsc_launcher/`
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
