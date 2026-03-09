# AI Agent Onboarding

This repository ships launchers and a VS Code extension to isolate Codex session state per project.

## Mission

- Keep launcher behavior predictable across Windows, WSL, Linux, and macOS.
- Keep extension behavior aligned with wizard-generated launcher behavior.
- Preserve user trust: project-scoped changes only, no hidden network behavior, no secret leakage.

## Fast Start

1. Confirm branch and workspace status:
   - `git status -sb`
2. Read these files first:
   - `README.md`
   - `CONTRIBUTING.md`
   - `docs/USAGE.md`
   - `docs/TRUST.md`
   - `docs/FEATURE_WORKFLOW.md` when the task is feature development
3. If the wizard is changed, sync and validate extension copy:
   - `cd extension`
   - `npm run sync:wizard`
   - `npm run compile`

## Critical Source Of Truth

- Wizard source of truth: `tools/vsc-launcher-wizard.ps1`
- Bundled extension copy: `extension/scripts/vsc-launcher-wizard.ps1`
- Sync script: `extension/scripts/sync-wizard.mjs`

Do not manually diverge these two wizard files. Update `tools/` then sync.

## Safety Rules

- Never add telemetry or outbound data upload behavior.
- Never log tokens, secrets, or full credential paths.
- Keep generated launcher artifacts project-local (`.vsc_launcher/`).
- Preserve backup behavior before overwriting managed files.
- Keep `.codex` credential-sensitive defaults protected in ignore strategy.

## Branch And Release Policy

- Feature/fix work targets `pre-release`.
- Promotion to `main` is from `pre-release`.
- Emergency exception uses label `allow-main-hotfix` and requires back-sync `main -> pre-release`.
- Every extension version change must create the matching git tag (`v<extension.version>`) in the same work session. Do not postpone tagging.
- Keep the git flow clean after merges: sync local `main` / `pre-release` with origin, delete merged temporary branches, and avoid leaving stale release/sync branches behind.

## Validation Matrix

- Windows integration tests:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Windows.ps1`
- Linux/macOS integration tests:
  - `chmod +x ./tests/test-linux.sh && ./tests/test-linux.sh`
- Extension compile:
  - `cd extension && npm run compile`

## Change Checklist For Agents

1. Update code.
2. Update docs for behavioral changes.
3. Update `CHANGELOG.md` (`[Unreleased]`).
4. Run relevant tests.
5. Confirm clean `git status`.

## Feature Development Workflow

For feature development requests, follow `docs/FEATURE_WORKFLOW.md`.

Repository rule:

1. Create or update an idea file under `ideas/` before coding.
2. Act as an advisor during idea formation: surface breakage risk, stale assumptions, and better alternatives.
3. Do not guess through important ambiguity. Ask targeted clarification questions first, then update the idea file.
4. Break the work into logical, reviewable steps.
5. Summarize those steps for the user and get approval before implementation starts.
6. Execute one approved step at a time.
7. Stop after each step for user review/approval.
8. Include a dedicated alignment-review step against the original idea.
9. Include a dedicated user-testing handoff step.
10. Finish with a commit-readiness checkpoint before committing feature work.

The idea file must be detailed enough for another model to continue the work with minimal ambiguity.
