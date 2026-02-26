# Changelog

All notable changes to this extension are documented in this file.

## [Unreleased]

### Added

- `Codex Session Isolator: Dry Run Initialize` command to preview file changes and resolved `CODEX_HOME` without writing files.

### Changed

- Version aligned to repository release line (`0.3.4`) so extension version and stable git tag can match.
- Stable release posture changed to non-preview manifest (`preview` removed from `package.json`).
- Initialization confirmation detail now uses the same per-file plan and backup behavior summary shown by Dry Run.
- Extension README now documents modified files and cleanup/uninstall steps.

## [0.1.0] - 2026-02-25

### Added

- Initial VS Code extension release for Codex Session Isolator.
- Command palette actions for initialize/reopen/logs/config workflows.
- Hybrid execution model: VS Code UX + bundled PowerShell launcher wizard backend.
- Marketplace assets and metadata (icon, hero image, links, keywords).
