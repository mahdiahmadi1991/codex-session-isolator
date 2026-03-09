# Rollback Launcher Changes

## Feature Summary

Add a rollback capability that reverts launcher-related changes previously applied to a consumer project.

The rollback flow must be available from the VS Code extension and should follow the same target-selection model as setup:

- `Current project`
- `Another project`

This feature is intentionally scoped to launcher-managed artifacts only. It must not touch unrelated project content.

## Goal

Let a user explicitly undo launcher setup for a selected project in a safe and inspectable way.

Success means:

- launcher-generated files are removed
- wizard-managed settings are restored or removed safely
- wizard-managed `.gitignore` changes are reverted safely
- rollback refuses to proceed when ownership is ambiguous

## User-Facing Behavior

### New command

Add a new command in the extension:

- `Codex Session Isolator: Rollback Launcher Changes`

### Target selection

Reuse the existing target-selection UX:

- `Current project (recommended)`
- `Another project`

Behavior:

- `Current project`: rollback the active project
- `Another project`: pick a different project path without closing the current VS Code window

### Confirmation

Before execution, keep rollback prompts explicit and limited to the decisions that are actually needed:

- target root
- whether rollback metadata exists
- whether launcher files will be deleted
- whether settings and `.gitignore` will be restored from backup or cleaned surgically

### Completion

After success:

- show a concise summary of what was removed or restored
- do not auto-reopen or auto-close VS Code

### Failure

Fail closed when rollback safety is not provable.

Examples:

- rollback metadata missing
- latest backup session missing or inconsistent
- required restore source missing
- selected target is not a launcher-managed project

## Scope

Rollback should target launcher-managed changes only:

- `vsc_launcher.bat`
- `vsc_launcher.sh`
- project-local Windows shortcut if generated
- `.vsc_launcher/`
- `.vscode/settings.json` when modified by the wizard
- selected `.code-workspace` settings block when modified by the wizard
- wizard-managed block inside `.gitignore`
- generated workspace file when the wizard created it

## Non-Goals

- rolling back anything inside `.codex/`
- removing or restoring user source files
- changing global VS Code settings
- rolling back projects initialized before rollback metadata existed, unless a later iteration explicitly adds legacy best-effort support

## Safety / Trust Boundaries

- never touch `.codex/`
- never remove or restore files outside the wizard-managed surface, except an explicitly generated shortcut owned by the tool
- prefer exact restore from backup over best-effort mutation when backup exists
- fail closed if ownership or intent is ambiguous
- remove `.vsc_launcher/` only after all earlier rollback operations succeed
- prefer reversible removal over permanent deletion for launcher-owned artifacts
- do not discard user edits in managed files; revert only wizard-owned changes wherever practical

## Assumptions

- v1 does not need legacy backward-compatibility behavior, but rollback metadata must be versioned for future compatibility work
- rollback should revert only the latest applied launcher state
- extension should remain the UX layer while PowerShell remains the source of truth for file operations
- existing backup behavior can be extended with explicit rollback metadata

## Risks / Edge Cases

- a user may have edited wizard-managed files after setup
- the wizard may have created a workspace file that did not exist before setup
- the Windows shortcut may live outside project root
- rollback metadata may exist while referenced backup files are incomplete
- multiple setup runs may exist for the same project

## Open Questions / Resolutions

### Resolved decisions

- rollback targets only the latest known launcher state
- v1 does not need legacy backward-compatibility handling for pre-metadata setups
- rollback metadata should include an explicit version for future compatibility/migration work
- missing shortcut targets warn without failing the whole rollback
- backend script and extension both gain rollback entry points in v1
- removal should be reversible rather than immediately permanent
- the intended reversible target is the operating system Trash/Recycle Bin, not only a project-local quarantine
- rollback should preserve post-setup user edits and surgically reverse only wizard-managed changes in files like `.gitignore`, `.vscode/settings.json`, and workspace files when feasible
- Linux trash behavior should follow the freedesktop Trash layout under the user's data directory rather than an ad hoc custom folder layout
- Windows should target Recycle Bin behavior
- macOS should target native Trash behavior
- if native Trash/Recycle Bin is unavailable or unreliable, ask the user whether to stop or continue with permanent deletion
- the fallback prompt must be contextual and appear only when rollback actually needs to remove launcher-owned artifacts
- the default fallback choice must be `Stop`, not permanent deletion

### Advisory notes

- `Trash/Recycle Bin` is the right trust-oriented UX, but true OS-trash behavior is not equally deterministic across Windows, WSL, Linux, and macOS. v1 needs an explicit rule for what to do when native trash is unavailable or unreliable.
- Fallback prompting must be state-aware. If rollback only needs surgical edits or restores and no launcher-owned artifacts need removal, the permanent-delete fallback prompt should not appear.
- On Linux, the correct model is the freedesktop Trash spec, which uses a Trash directory with `files/` and `info/` metadata. Simply mirroring the original project tree under `~/.local/share/Trash/` would not be spec-compliant by itself.
- WSL remains a special case: the target project may live on the Linux filesystem while the backend entry point may originate from Windows-oriented tooling. That is implementable, but it strengthens the case for a strict fail-closed rule when native trash behavior cannot be executed confidently.
- Surgical rollback of `.gitignore`, `.vscode/settings.json`, and workspace settings is the correct trust-oriented direction, but only if ownership is explicit and bounded. This means Step 1 metadata must capture enough information to reverse only wizard-managed changes.
- Because backward compatibility is not required yet, this is the right time to add manifest versioning and ownership metadata now, before public adoption hardens the format.

## Affected Areas

### Backend

- [tools/vsc-launcher-wizard.ps1](../tools/vsc-launcher-wizard.ps1)
- [extension/scripts/vsc-launcher-wizard.ps1](../extension/scripts/vsc-launcher-wizard.ps1)

### Extension

- [extension/src/extension.ts](../extension/src/extension.ts)
- [extension/package.json](../extension/package.json)

### Tests

- [tests/Test-Windows.ps1](../tests/Test-Windows.ps1)
- [tests/test-linux.sh](../tests/test-linux.sh)
- extension unit tests if command parsing or UX helpers need coverage

### Docs

- user docs covering setup and extension commands
- changelog

## Technical Direction

### Source of truth

Implement rollback behavior in the PowerShell backend, not only in the extension.

Reason:

- file ownership and restore/delete logic already lives closest to the wizard
- setup and rollback stay aligned across direct script usage and extension usage
- Windows-specific path handling stays in one place

### Rollback metadata

Add a rollback manifest under `.vsc_launcher/`, for example:

- `.vsc_launcher/rollback.manifest.json`

This metadata should capture enough state to answer:

- which files were created by setup
- which files existed before setup
- which files have backups
- whether a workspace file was generated by the wizard
- whether a Windows shortcut was created and where
- which backup session maps to the current setup state
- manifest schema version for future migration/backward-compatibility support

### Preferred v1 rule

Require rollback metadata in v1.

If the target was initialized before rollback metadata existed:

- detect that case
- stop safely
- explain that automatic rollback is unavailable for legacy setups

## Validation Strategy

Validation will be split by implementation step.

Expected final coverage:

- backend setup writes rollback metadata correctly
- backend rollback restores or removes only managed files
- extension command can target current or external project
- confirmation and completion UX remain clear
- missing-manifest path fails safely
- docs match actual behavior

## Execution Steps

### Step 1: Define rollback metadata and persist it during setup

Status:

- `Completed`

Purpose:

- establish the ownership model required for safe rollback

Planned work:

- design manifest structure
- write manifest during successful setup
- ensure manifest references the latest relevant backup session
- include manifest schema version and ownership fields needed for safe rollback behavior
- sync the bundled extension wizard copy

Expected outputs:

- rollback manifest design implemented in the PowerShell wizard
- setup path persists rollback metadata after successful generation

Validation:

- compile extension after wizard sync
- run targeted automated checks that confirm setup still succeeds

Approval gate:

- stop after implementation and wait for user review before Step 2

### Step 2: Implement backend rollback mode and rollback plan execution

Status:

- `Completed`

Purpose:

- add the actual rollback engine in the backend

Planned work:

- add rollback entry point and argument handling
- load and validate rollback manifest
- compute restore/delete plan
- restore backed-up files where applicable
- surgically remove managed `.gitignore` block and wizard-owned settings changes without discarding unrelated user edits
- move launcher-owned files to OS Trash/Recycle Bin when supported by the execution environment
- remove generated launcher files metadata only after all earlier rollback operations succeed

Expected outputs:

- backend rollback mode works for direct script usage
- rollback fails safely when metadata is missing or inconsistent

Validation:

- focused backend/integration checks for success and failure paths

Approval gate:

- stop after implementation and wait for user review before Step 3

### Step 3: Add extension rollback command and target-selection flow

Status:

- `Completed`

Purpose:

- expose rollback in the extension with the same project-selection model as setup

Planned work:

- register new rollback command and any legacy alias needed
- reuse target-selection flow for current vs another project
- add confirmation UX
- add completion and failure reporting

Expected outputs:

- rollback is invokable from the command palette
- current and external project flows both work

Validation:

- `cd extension && npm run compile`
- `cd extension && npm run test:unit`

Approval gate:

- stop after implementation and wait for user review before Step 4

### Step 4: Add and update automated tests and documentation

Status:

- `Completed`

Purpose:

- align tests and docs with the delivered rollback behavior

Planned work:

- add Windows integration coverage
- add Linux/macOS integration coverage where supported
- update extension and user docs
- update `CHANGELOG.md`

Expected outputs:

- tests cover the supported rollback paths
- docs explain the new capability and its constraints

Validation:

- `./tests/test-linux.sh`
- `cd extension && npm run test:unit`
- Windows integration coverage added in `tests/Test-Windows.ps1` but not executed in this environment

Approval gate:

- stop after implementation and wait for user review before Step 5

### Step 5: Compare implementation against the original idea

Status:

- `Completed`

Purpose:

- find mismatches between intended behavior and delivered behavior

Planned work:

- compare each implemented behavior against this idea file
- list any missing pieces or deviations
- either fix approved gaps or explicitly record accepted differences

Expected outputs:

- a concise mismatch review with resolution status

Validation:

- direct review against this document

Approval gate:

- stop after the mismatch review and wait for user approval before Step 6

Alignment review:

- `Match`: rollback exists in both backend helper flow and VS Code extension flow.
- `Match`: extension rollback uses the same `Current project` / `Another project` target-selection model as setup.
- `Match`: rollback is scoped to launcher-managed artifacts only and does not target `.codex/`.
- `Match`: rollback requires versioned manifest metadata and fails closed when manifest safety cannot be proven.
- `Match`: launcher-owned artifacts are removed through native Trash/Recycle Bin when supported, with `Stop` as the default fallback choice when native trash is unavailable.
- `Match`: `.vscode/settings.json`, workspace settings, and the managed `.gitignore` block are rolled back surgically to preserve user edits.
- `Match`: generated workspace removal, shortcut handling, and latest-setup-only behavior are all implemented.
- `Accepted difference`: when rollback metadata is missing, the extension shows an immediate fail-closed warning instead of presenting a confirmation dialog that says metadata is missing. This is stricter than the original summary wording but aligns with the trust model.
- `Residual validation gap`: Windows rollback integration coverage is implemented in `tests/Test-Windows.ps1`, but it was not executed in this environment.

### Step 6: Prepare user-testing handoff and edge-case checklist

Status:

- `Completed`

Purpose:

- prepare the user to run realistic manual testing

Planned work:

- summarize what is ready to test
- list test environments and prerequisites
- list edge cases to verify
- note known limitations or unsupported legacy cases

Expected outputs:

- a clear, actionable test checklist for the user

Validation:

- internal consistency review only

Approval gate:

- wait for user confirmation before moving to Step 7

User-testing handoff:

- `Recommended order`: test first in a disposable project copy, then in a real project you care about.
- `Extension under test`: use the local build already installed from this branch.
- `Minimum target shape for meaningful coverage`: a project with an existing `.gitignore` and at least one `.code-workspace` file.
- `Important trust expectation`: rollback must not touch `.codex/`, must not auto-close or auto-reopen VS Code, and must preserve unrelated user edits in managed files.

Suggested manual test sequence:

1. `Happy path / current project`
   - run `Codex Session Isolator: Setup Launcher`
   - keep defaults unless the test specifically needs a different path
   - confirm launcher artifacts are created
   - run `Codex Session Isolator: Rollback Launcher Changes` for `Current project`
   - expected:
     - only the required rollback prompts appear before changes
     - rollback completes without reopening VS Code
     - launcher file is removed
     - `.vsc_launcher/` is removed when it was created by setup
     - `.codex/` remains untouched

2. `Happy path / another project`
   - from some other workspace window, run rollback and choose `Another project`
   - point to a project previously initialized by setup
   - expected:
     - current VS Code window stays open
     - rollback completion report clearly states that another project was targeted

3. `User edits must survive`
   - after setup, add your own entry to `.gitignore`
   - add your own custom key to `.vscode/settings.json`
   - if a workspace file is used, add your own custom workspace setting
   - then rollback
   - expected:
     - managed `codex-session-isolator` gitignore block is removed
     - your extra `.gitignore` line remains
     - wizard-managed settings are removed or restored
     - your custom settings remain

4. `Missing manifest fails closed`
   - choose a project that was never initialized by this branch's setup flow, or manually remove `.vsc_launcher/rollback.manifest.json`
   - run rollback
   - expected:
     - rollback refuses to proceed
     - no project files are changed
     - extension/backend explains that rollback metadata is missing or unsupported

5. `Latest-setup-only behavior`
   - run setup twice on the same project
   - then rollback once
   - expected:
     - rollback undoes the latest known setup state only
     - it does not guess across older unrelated history

6. `Session history tracking interaction`
   - run setup with `Track Codex session history in git = Yes`
   - confirm the managed `.gitignore` block keeps:
     - `.codex/config.toml`
     - `.codex/sessions/**`
     - `.codex/archived_sessions/**`
     - `.codex/memories/**`
     - `.codex/session_index.jsonl`
   - then rollback
   - expected:
     - only the managed block is removed
     - `.codex/` contents are still not deleted by rollback

Optional advanced checks:

- `WSL-hosted target with Windows shortcut`
  - if setup generated `Open <project>.lnk`, rollback should remove or restore that launcher-owned shortcut when safe
  - if the shortcut was moved manually, rollback should warn or skip without breaking the whole flow

- `Native Trash/Recycle Bin behavior`
  - if your environment supports native trash semantics, removed launcher-owned files should go there rather than being hard-deleted
  - if you can reproduce an unsupported-trash path, the fallback choice should default to `Stop`

- `Generated workspace cleanup`
  - use a folder that had no workspace file before setup
  - let setup create one
  - rollback should remove that generated workspace file if it is still wizard-owned

Known limitations to keep in mind during testing:

- rollback supports setups created with rollback metadata only; legacy setups are intentionally fail-closed in v1
- Windows automated rollback coverage was added but has not been executed in this environment yet
- the permanent-delete fallback only matters when launcher-owned artifact removal is actually required; it should not appear during pure surgical-edit cases

### Step 7: Final readiness review for commit

Status:

- `Completed`

Purpose:

- confirm the branch is ready for a feature commit once user testing is accepted

Planned work:

- summarize completed scope
- summarize validations
- confirm workspace status
- identify any remaining known gaps

Expected outputs:

- explicit commit-readiness summary

Validation:

- check final repository state and test results

Approval gate:

- commit only after user approval

Commit-readiness review:

- `Scope delivered`: rollback metadata, backend rollback execution, helper entry points, extension command/UX, tests, docs, and changelog updates are all present on this branch.
- `Automated validation completed in this environment`:
  - `./tests/test-linux.sh`
  - `cd extension && npm run test:unit`
  - `cd extension && npm run package`
- `Local install completed`: local VSIX `extension/codex-session-isolator-0.3.11.vsix` was built and installed into the WSL VS Code environment for manual testing.
- `Workspace status`: branch is intentionally not clean because feature changes are still uncommitted, and `docs/FEATURE_WORKFLOW.md` remains an uncommitted tracked addition for the new workflow rule.
- `Known remaining gap`: Windows rollback integration coverage exists in `tests/Test-Windows.ps1` but was not executed in this environment.
- `Commit status`: branch appears ready for a feature commit after manual testing, but commit is intentionally withheld until explicit user approval.

## Current Status

- workflow updated to follow the repository's new feature-development rule
- this idea document has been restructured into approval-gated steps
- advisory-mode clarification completed
- Step 1 completed: rollback manifest metadata is now written during setup
- Step 2 completed: backend rollback mode now restores or removes launcher-managed artifacts with smart fallback prompting
- Step 3 completed: extension rollback command now supports current-project vs another-project targeting, confirmation UX, and completion reporting
- Step 4 completed: docs, changelog, and automated coverage are now aligned with rollback behavior
- Step 5 completed: implementation was compared against the idea and no blocking behavior mismatch was found
- Step 6 completed: a user-testing handoff and edge-case checklist is now prepared for manual validation
- Step 7 completed: branch readiness was reviewed, local VSIX was installed, and commit remains intentionally pending user approval
- next action is manual user testing, then explicit approval or follow-up fixes
