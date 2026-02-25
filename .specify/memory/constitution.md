<!--
Sync Impact Report
- Version change: template-unversioned -> 1.0.0
- Modified principles:
  - Template Principle 1 -> I. Project-Scoped Isolation First
  - Template Principle 2 -> II. Wizard and Extension Source-of-Truth Sync
  - Template Principle 3 -> III. Security and Secret Hygiene (Non-Negotiable)
  - Template Principle 4 -> IV. Cross-Platform Determinism
  - Template Principle 5 -> V. Verification and Release Discipline
- Added sections:
  - Operational Constraints
  - Delivery Workflow and Quality Gates
- Removed sections:
  - None
- Templates requiring updates:
  - ✅ .specify/templates/plan-template.md
  - ✅ .specify/templates/tasks-template.md
  - ✅ .specify/templates/spec-template.md (reviewed, no change needed)
  - ✅ .specify/templates/checklist-template.md (reviewed, no change needed)
- Follow-up TODOs:
  - None
-->

# Codex Session Isolator Constitution

## Core Principles

### I. Project-Scoped Isolation First
All launcher and extension behavior MUST remain project-scoped. Generated
artifacts MUST stay under `.vsc_launcher/` and project-local `.codex` for the
selected target. The project MUST NOT modify global shell profiles or global
Codex defaults as part of normal operation. This preserves reversibility and
user trust.

### II. Wizard and Extension Source-of-Truth Sync
`tools/vsc-launcher-wizard.ps1` is the canonical wizard source. Any wizard
change MUST be authored there first, then synced to
`extension/scripts/vsc-launcher-wizard.ps1` via
`extension/scripts/sync-wizard.mjs` or `npm run sync:wizard`. The two copies
MUST NOT diverge in committed state.

### III. Security and Secret Hygiene (Non-Negotiable)
The project MUST NOT add telemetry or hidden outbound data upload behavior.
Code and logs MUST NOT expose tokens, secrets, or full credential paths.
Credential-sensitive `.codex` defaults MUST remain protected by ignore
strategy. Managed file overwrites MUST preserve backup behavior before write.

### IV. Cross-Platform Determinism
Behavior MUST stay predictable across Windows, WSL, Linux, and macOS. Path
routing rules, launcher defaults, and wizard prompts MUST be explicit and
documented. Any platform-specific behavior change MUST include matching docs
updates and validation evidence for impacted environments.

### V. Verification and Release Discipline
Every behavior change MUST run relevant validations from the repository matrix:
Windows integration tests for Windows/wizard/PowerShell launch flows, Linux/macOS
integration tests for shell launch flows, and extension compile for extension or
wizard-sync changes. User-visible behavior changes MUST update `CHANGELOG.md`
under `[Unreleased]`. Feature and fix work targets `pre-release` unless an
approved emergency main hotfix path is used.

## Operational Constraints

- Managed boundary: only modify known managed artifacts and settings blocks
  (`vsc_launcher.*`, `.vsc_launcher/*`, `.vscode/settings.json`, selected
  workspace settings, managed `.gitignore` block).
- Local-first behavior only: no hidden network side effects beyond explicit
  user-initiated tooling actions.
- Preserve safety backups under `.vsc_launcher/backups/<timestamp-pid>/`
  before overwriting managed files.
- Keep launcher artifacts project-local and avoid user-specific hardcoded paths.

## Delivery Workflow and Quality Gates

- Use spec-driven flow for non-trivial changes:
  `/speckit.specify` -> `/speckit.clarify` (optional) -> `/speckit.plan` ->
  `/speckit.tasks` -> `/speckit.analyze` (optional) -> `/speckit.implement`.
- During planning, the Constitution Check MUST explicitly validate all five core
  principles and document mitigation for any justified exception.
- Pull requests MUST include problem statement, implementation approach, and
  test evidence aligned with affected platforms.
- Behavioral changes MUST include docs updates in the affected user-facing
  guidance files.

## Governance

This constitution supersedes ad-hoc local process choices for this repository.
Amendments MUST be made through pull requests targeting `pre-release` and MUST
include: (1) version bump rationale, (2) affected principle/section deltas, and
(3) any required template or documentation propagation. Compliance checks happen
at plan review and pull request review.

Version policy:
- MAJOR: Backward-incompatible governance or principle redefinition/removal.
- MINOR: New principle or materially expanded mandatory guidance.
- PATCH: Clarifications that do not change normative meaning.

**Version**: 1.0.0 | **Ratified**: 2026-02-25 | **Last Amended**: 2026-02-25
