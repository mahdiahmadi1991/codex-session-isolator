# Repository AI Instructions

## Goal

Maintain safe, cross-platform Codex session isolation for launchers and extension workflows.

## High Priority

1. Preserve parity between:
   - `tools/vsc-launcher-wizard.ps1`
   - `extension/scripts/vsc-launcher-wizard.ps1`
2. Preserve backward compatibility for generated launchers.
3. Keep project-scoped isolation (`CODEX_HOME=<target>/.codex`).

## Required Checks For Wizard Changes

1. Sync wizard bundle:
   - `cd extension && npm run sync:wizard`
2. Build extension:
   - `cd extension && npm run compile`
3. Validate integration:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Windows.ps1`
   - `chmod +x ./tests/test-linux.sh && ./tests/test-linux.sh`

## Security And Privacy Guardrails

- Do not add telemetry uploads.
- Do not print secrets/tokens in logs.
- Keep generated artifacts under project-local dot folders.
- Keep credential-sensitive paths out of tracked files.

## Branching Guardrails

- Default base branch: `pre-release`.
- `main` accepts promotion from `pre-release` (except labeled hotfix override).

## Documentation Guardrails

For any behavior change, update:

- `README.md`
- `docs/USAGE.md` (if user-facing flow changed)
- `CHANGELOG.md` (`[Unreleased]`)
