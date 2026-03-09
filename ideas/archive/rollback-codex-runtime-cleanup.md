# Rollback Codex Runtime Cleanup

## Feature Summary

Extend rollback so the user can optionally remove project-local Codex runtime data under `.codex/` while still preserving `config.toml`.

This must remain an explicit opt-in choice during rollback, not a default behavior.

## Goal

Let the user choose between:

- rollbacking launcher-managed artifacts only
- rollbacking launcher-managed artifacts plus project-local Codex runtime data

Success means:

- the default remains conservative (`No`)
- `.codex/config.toml` remains preserved
- optional `.codex` cleanup uses the same trust-oriented removal model as launcher-owned artifacts
- the UX stays contextual and does not ask meaningless questions when no removable `.codex` runtime data exists

## Advisory Notes

- This is more destructive than the existing rollback behavior because it reaches beyond launcher-managed artifacts into user-generated runtime state.
- Even if the user asks for cleanup, the implementation should stay explicit, reversible where possible, and scope-bounded.
- This feature should not silently turn rollback into “delete all project Codex data”; the opt-in boundary needs to stay obvious.

## Current Findings

- Current rollback intentionally does not touch `.codex/`.
- In real-world usage, `.codex/` can accumulate enough files to keep a project dirty even after launcher rollback succeeds.
- The current completion UX for rollback still contains an `Open Logs` action that the user considers low-value and wants removed.

## Scope

- add an optional rollback prompt for `.codex` runtime cleanup
- preserve `.codex/config.toml`
- remove the low-value `Open Logs` action from rollback completion UX
- keep docs/tests/changelog aligned

## Non-Goals

- changing default rollback to delete `.codex` automatically
- deleting `.codex/config.toml`
- changing the existing trust boundary for unrelated project files

## Open Questions / Resolutions

### Resolved decisions

- When the user chooses `Yes`, rollback should remove everything under `.codex/` except `.codex/config.toml`.
- The cleanup prompt should be shown only when `.codex/` exists and contains at least one removable entry beyond `config.toml`.
- The rollback completion action button `Open Logs` should be removed from the extension UX.

## Proposed Direction

### Rollback UX

- During rollback, after target confirmation and before execution, ask:
  - `Also remove project Codex runtime data?`
- Default choice:
  - `No`
- Only show this question when `.codex/` exists and contains removable entries besides `config.toml`.

### Runtime cleanup scope

- preserve:
  - `.codex/config.toml`
- remove when user opts in:
  - all other files/directories under `.codex/`, including auth/runtime/session/cache/skill data
- removal strategy:
  - same native Trash/Recycle Bin first
  - same fallback `Stop / Delete permanently` behavior when native trash is unavailable

### Completion UX cleanup

- remove the rollback completion action button:
  - `Open Logs`

## Risks / Edge Cases

- deleting `.codex` runtime data may remove state the user still wants
- opting in will also remove local auth/runtime artifacts such as cached credentials or state databases if they live under `.codex/`
- `.codex` may contain sensitive auth/runtime artifacts, so the prompt wording must make scope obvious
- if only `config.toml` remains, rollback should avoid leaving confusing empty-directory behavior

## Expected Affected Areas

- `tools/vsc-launcher-wizard.ps1`
- `extension/scripts/vsc-launcher-wizard.ps1`
- `extension/src/extension.ts`
- docs and tests

## Execution Steps

### Step 1: Clarify scope and finalize proposal

Status:

- `Completed`

Purpose:

- close destructive-scope ambiguities before implementation

### Step 2: Add backend support for optional `.codex` runtime cleanup

Status:

- `Completed`

Purpose:

- make rollback optionally schedule `.codex` runtime removals while preserving `config.toml`

Implementation notes:

- Added backend rollback support for opt-in `.codex` cleanup that removes all runtime entries under `.codex/` except `config.toml`.
- Backend preflight now includes these optional `.codex` removals before mutating managed files, so unsupported native-trash cases still fail safely before edits.
- Added helper flag plumbing for backend invocation paths so the new cleanup mode is reachable outside the extension UX when needed.
- Added Linux regression coverage that verifies `config.toml` is preserved while other `.codex` runtime data is removed.

### Step 3: Add extension UX for the new cleanup choice and remove `Open Logs`

Status:

- `Completed`

Purpose:

- expose the opt-in choice clearly and simplify completion UX

Implementation notes:

- Extension rollback now asks `Also remove project Codex runtime data?` only when `.codex/` exists and contains removable entries beyond `config.toml`.
- The default user-facing answer remains `No`.
- The chosen cleanup mode is now logged and passed through to backend rollback execution.
- The rollback completion modal no longer includes the `Open Logs` action.

### Step 4: Update tests, docs, and changelog

Status:

- `Completed`

Purpose:

- keep behavior validated and documented

Implementation notes:

- Updated user-facing docs to describe the optional `.codex` cleanup prompt, the default `No` choice, and the guarantee that `config.toml` is preserved.
- Updated manual testing guidance to cover the optional `.codex` cleanup branch.
- Updated changelog for the new rollback cleanup option and the removal of `Open Logs` from rollback completion UX.
- Linux integration coverage now includes the `.codex` cleanup case.

### Step 5: Compare implementation against the idea

Status:

- `Completed`

Purpose:

- confirm the delivered rollback behavior still matches the agreed destructive-scope and UX constraints

Planned work:

- compare the backend cleanup scope against the approved `.codex` policy
- compare the extension prompt behavior against the agreed smart-prompt behavior
- compare rollback completion UX against the agreed removal of the low-value log action
- record any accepted differences or remaining validation gaps

Expected outputs:

- a short alignment review with any residual risks called out explicitly

Validation:

- direct review against this idea file and the implemented source/docs/tests

Approval gate:

- stop after the alignment review and wait for user approval before Step 6

Alignment review:

- `Match`: rollback can now optionally schedule cleanup for all project-local `.codex` runtime data while preserving `.codex/config.toml`.
- `Match`: the extension asks `Also remove project Codex runtime data?` only when `.codex/` exists and contains at least one removable entry beyond `config.toml`.
- `Match`: the default answer remains `No`; the cleanup path is opt-in rather than implicit.
- `Match`: opted-in `.codex` removals use the same rollback removal pipeline and the same native Trash/Recycle Bin fallback behavior as launcher-owned artifact removal.
- `Match`: rollback completion no longer offers the `Open Logs` action in the extension UX.
- `Match`: user-facing docs, testing guidance, and changelog entries were updated to reflect the new optional cleanup branch.
- `Accepted difference`: the cleanup prompt is implemented as a separate confirmation step after rollback target confirmation, rather than being folded into the earlier summary dialog. This keeps the destructive choice isolated and still satisfies the agreed UX constraints.
- `Residual validation gap`: Linux integration coverage exists for the `.codex` cleanup branch, but Windows-specific integration coverage for this new branch was not executed in this environment.

### Step 6: Prepare user-testing handoff

Status:

- `Completed`

Purpose:

- hand off realistic rollback test expectations for the new optional `.codex` cleanup branch

Implementation notes:

- Manual testing was performed on a real WSL-backed consumer project during the bug-fix loop for rollback and `.codex` cleanup behavior.
- The optional `.codex` cleanup path now completes successfully on the tested WSL-backed project and preserves `.codex/config.toml`.
- Remaining `.codex/tmp` entries appear to be recreated by active Codex/runtime tooling rather than left behind by rollback failure.

### Step 7: Final readiness review for commit

Status:

- `Completed`

Purpose:

- confirm that the optional `.codex` cleanup work is ready to ship with the broader rollback feature

Commit-readiness review:

- `Scope delivered`: rollback can now optionally clean `.codex` runtime data while preserving `config.toml`, and the rollback completion UX no longer offers `Open Logs`.
- `Automated validation completed in this environment`:
  - `./tests/test-linux.sh`
  - `cd extension && npm run test:unit`
- `Manual validation`: rollback with optional `.codex` cleanup was exercised against a real WSL-backed project during bug-fix validation.
- `Known remaining gap`: Windows-specific integration coverage for this opt-in branch was not executed in this environment.
- `Commit status`: ready to be committed as part of the rollback feature branch.

## Current Status

- idea created
- clarification completed
- Step 1 completed: destructive-scope decisions and UX constraints are now fixed in the proposal
- Step 2 completed: backend rollback can now optionally remove `.codex` runtime data while preserving `config.toml`
- Step 3 completed: extension rollback now exposes the opt-in `.codex` cleanup choice and the rollback completion UX no longer offers `Open Logs`
- Step 4 completed: tests, docs, and changelog were aligned with the new optional `.codex` cleanup behavior
- Step 5 completed: implementation was compared against the idea and no blocker mismatch was found
- Step 6 completed: user-testing expectations and real-project rollback observations were recorded
- Step 7 completed: final readiness was reviewed and the work is ready to ship with the rollback branch
