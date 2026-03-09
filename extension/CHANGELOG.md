# Changelog

All notable changes to this extension are documented in this file.

## [Unreleased]

## [0.3.12] - 2026-03-09

### Added

- Rollback support for the latest launcher-managed setup, including current-project vs another-project targeting and safe rollback metadata.
- Unit coverage that locks the supported command surface and guards against legacy command drift in the extension manifest.

### Changed

- Public command surface now centers on `Setup Launcher`, `Reopen With Launcher`, and `Rollback Launcher Changes`, with obsolete legacy commands removed.
- Marketplace-facing README presentation now emphasizes trust, tested environments, and clearer command discovery.
- Extension rollback can optionally remove project `.codex` runtime data while preserving `.codex/config.toml`.
- Rollback completion no longer offers the low-value `Open Logs` action.

## [0.3.10] - 2026-03-02

### Changed

- Version aligned to repository release line (`0.3.4`) so extension version and stable git tag can match.
- Stable release posture changed to non-preview manifest (`preview` removed from `package.json`).
- Marketplace README quick start now includes install/setup/verify flow and optional one-click setup command usage when available.
- Marketplace README now includes cleanup/uninstall instructions and concise troubleshooting guidance with log locations.

## [0.1.0] - 2026-02-25

### Added

- Initial VS Code extension release for Codex Session Isolator.
- Command palette actions for initialize/reopen/logs/config workflows.
- Hybrid execution model: VS Code UX + bundled PowerShell launcher wizard backend.
- Marketplace assets and metadata (icon, hero image, links, keywords).
