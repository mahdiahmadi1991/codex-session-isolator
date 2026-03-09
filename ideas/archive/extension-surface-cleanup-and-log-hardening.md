# Extension Surface Cleanup And Log Hardening

## Feature Summary

Clean up the extension command surface and user-facing documentation while strengthening project-local logging so troubleshooting does not depend on the user manually collecting and pasting logs.

This work includes:

- removing obsolete legacy extension command IDs and their supporting fallback logic
- collapsing redundant public commands where the user-facing behavior is effectively the same
- replacing user-specific filesystem paths in committed user-facing content with generic examples
- ensuring extension-driven operations leave enough project-local log evidence to debug failures later

## Goal

Reduce UX confusion, remove dead compatibility surface, protect privacy in committed docs/help text, and make extension-driven flows easier to diagnose from local project logs.

Success means:

- there is only one public setup command for launcher generation
- obsolete legacy command IDs and legacy namespace fallback logic are removed
- user-facing examples and docs contain only generic sample paths
- extension-driven operations emit sufficient project-local logs for later investigation
- code, docs, tests, and marketplace-facing metadata remain aligned

## Advisory Notes

- Removing legacy command IDs is a deliberate breaking change for old keybindings/tasks that still reference `codexProjectIsolator.*`. This is acceptable only because you explicitly asked for removal.
- Removing `Initialize Launcher` is safe only because its public behavior currently overlaps with `Setup Launcher`. Internal helper functions may still exist if they are needed to keep code structure sane.
- Logging must stay local-first and project-scoped where possible. We should not replace trust-preserving local logs with telemetry or global upload behavior.
- Privacy cleanup should not be limited to markdown docs. Any user-facing help text or examples shipped in scripts should also avoid personal host paths.

## Current Findings

- `Initialize Launcher` and `Setup Launcher` currently resolve to effectively the same public setup flow.
- Legacy command IDs under `codexProjectIsolator.*` are still registered and still appear in extension metadata.
- Extension settings lookup still falls back to the legacy namespace.
- Some user-facing examples still contain user-specific absolute paths.
- Backend wizard logging already exists under `.vsc_launcher/logs`, but extension-side decision points are primarily visible in the VS Code output channel rather than a project-local log trail.

## Scope

- extension command cleanup
- extension logging hardening for setup/reopen/rollback flows
- removal of legacy namespace fallback logic that exists only to support removed legacy command/config surface
- user-facing path genericization across docs and help text
- test/doc/changelog synchronization for the resulting behavior

## Non-Goals

- changing launcher runtime semantics beyond what is needed for logging
- adding telemetry or remote log shipping
- preserving backward compatibility for removed legacy command IDs
- changing `.codex` storage behavior

## Affected Areas

### Extension

- `extension/src/extension.ts`
- `extension/package.json`

### Helpers / user-facing help text

- `tools/vsc-launcher.ps1`
- any other user-facing helper text that currently embeds host-specific paths

### Docs

- `README.md`
- `docs/USAGE.md`
- `docs/EXTENSION.md`
- `extension/README.md`
- related docs if they mention removed commands or personal paths

### Tests

- extension unit tests if command surface changes need direct coverage
- integration tests only where behavior actually changes

## Technical Direction

### Command surface

- keep `Codex Session Isolator: Setup Launcher`
- remove public `Codex Session Isolator: Initialize Launcher`
- keep `Reopen With Launcher`, `Rollback Launcher Changes`, `Open Launcher Logs`, `Open Launcher Config`
- remove all `codexProjectIsolator.*` registrations and manifest contributions

### Logging

- keep the VS Code output channel
- add or strengthen project-local extension operation logging so setup/reopen/rollback decisions can be reconstructed later from the target project's `.vsc_launcher/logs`
- logging should capture:
  - operation type
  - target root
  - chosen scope (`Current project` / `Another project`)
  - key flow outcomes
  - failures and fallback decisions

### Privacy cleanup

- replace committed user-specific paths with generic examples such as `/path/to/project` or `/home/user/projects/my-app`
- review both docs and script help/usage text

## Risks / Edge Cases

- old automation referencing removed legacy command IDs will stop working
- docs may still describe `Initialize Launcher` as a fallback path unless all references are updated
- logging must not fail the main operation if the log file cannot be written
- external-target operations need enough context in logs without confusing them with the current workspace

## Validation Strategy

- extension compile
- extension unit tests
- targeted integration tests only if command/logging behavior touches wizard/backend invocation materially
- direct review for path genericization and doc consistency

## Execution Steps

### Step 1: Clean up public command surface and legacy extension IDs

Status:

- `Completed`

Purpose:

- remove obsolete command surface and simplify user-facing setup flow

Planned work:

- remove legacy command IDs from extension registration and package manifest
- remove legacy namespace fallback logic where it exists only for those removed surfaces
- remove public `Initialize Launcher` command from the extension manifest and docs
- keep internal helper structure only if still useful

Expected outputs:

- one public setup command remains
- no legacy command IDs remain in the extension manifest or runtime registration

Validation:

- `cd extension && npm run compile`
- `cd extension && npm run test:unit`

Approval gate:

- stop after implementation and wait for user review before Step 2

### Step 2: Harden project-local logging for extension-driven operations

Status:

- `Completed`

Purpose:

- make later debugging possible from local logs without depending on user-pasted output

Planned work:

- add project-local extension operation logging for setup/reopen/rollback flows
- ensure failures and fallback decisions are recorded
- keep logging best-effort and non-blocking

Expected outputs:

- project-local logs contain enough flow breadcrumbs for later debugging

Validation:

- `cd extension && npm run compile`
- `cd extension && npm run test:unit`

Approval gate:

- stop after implementation and wait for user review before Step 3

### Step 3: Genericize user-specific paths and sync docs/help text

Status:

- `Completed`

Purpose:

- remove personal host-path leakage and keep docs user-safe

Planned work:

- replace user-specific paths in docs and shipped help text
- remove stale references to removed commands
- ensure docs consistently describe the simplified command surface

Expected outputs:

- no committed user-facing path examples expose personal host paths
- docs describe the current command surface only

Validation:

- direct review with repo-wide search

Implementation notes:

- PowerShell launcher help examples now use generic sample paths rather than user-specific host paths.
- Idea documents no longer embed personal absolute filesystem paths; internal references use relative repository links instead.
- Repo-wide search confirmed there are no remaining committed personal absolute-path examples in tracked docs/help text.

Approval gate:

- stop after implementation and wait for user review before Step 4

### Step 4: Update tests, changelog, and consistency docs

Status:

- `Completed`

Purpose:

- keep the rest of the repository aligned with the new surface

Planned work:

- update tests impacted by command/logging changes
- update `CHANGELOG.md`
- update any trust/testing docs affected by the new logging behavior

Expected outputs:

- project remains internally consistent

Validation:

- relevant automated suites

Implementation notes:

- Added an extension unit test that locks the public command surface and ensures legacy command IDs do not return through manifest drift.
- Updated changelog, trust guidance, testing guidance, and user-facing troubleshooting docs to describe local extension breadcrumbs and the simplified command surface.

Approval gate:

- stop after implementation and wait for user review before Step 5

### Step 5: Compare implementation against the original idea

Status:

- `Completed`

Purpose:

- verify that cleanup/logging/privacy goals were actually met

Planned work:

- review delivered behavior against this document
- record matches, accepted differences, and remaining gaps

Expected outputs:

- concise mismatch review

Validation:

- direct review against this idea file

Alignment review:

- `Match`: only one public setup command remains in the extension surface, and `Initialize Launcher` is no longer exposed.
- `Match`: legacy `codexProjectIsolator.*` command registrations and legacy namespace fallback logic were removed from the extension runtime and manifest.
- `Match`: committed user-facing examples now use generic sample paths rather than personal host-specific paths.
- `Match`: extension setup, reopen, and rollback now emit best-effort project-local breadcrumbs under `.vsc_launcher/logs` when that directory already exists, while still writing to the VS Code output channel.
- `Match`: tests, changelog, and consistency docs were updated to reflect the simplified command surface and logging model.
- `Accepted implementation constraint`: setup failures that happen before `.vsc_launcher/logs` exists are still only visible in the VS Code output channel. This is intentional to avoid creating project-owned metadata/log directories before setup has actually succeeded.
- `No blocking mismatch found`: the delivered implementation satisfies the feature goals within the documented trust constraints.

Approval gate:

- stop after the mismatch review and wait for user approval before Step 6

### Step 6: Prepare user-testing handoff and checklist

Status:

- `Completed`

Purpose:

- prepare a focused manual test pass for the cleaned-up command surface and logging behavior

Planned work:

- list the tests the user should run
- state the expected result for each test
- note any known limitations

Expected outputs:

- actionable manual test checklist

Validation:

- internal consistency review only

User-testing handoff:

- `Recommended order`: first verify the cleaned command surface, then verify local logging behavior on a disposable project, then repeat on a real project if needed.
- `Environment`: use the locally installed extension build from this branch.
- `Important expectation`: this feature should change extension UX clarity and logging behavior only. It should not change launcher generation semantics beyond the already-documented rollback/helper work on this branch.

Suggested manual tests:

1. `Command Palette surface`
   - open the Command Palette and search for `Codex Session Isolator`
   - expected:
     - `Setup Launcher` is present
     - `Reopen With Launcher` is present
     - `Rollback Launcher Changes` is present
     - `Initialize Launcher` is not present
     - no `Legacy` command variants are present

2. `Open Logs / Open Config utility commands`
   - on a project that has already been set up, run:
     - `Codex Session Isolator: Open Launcher Logs`
     - `Codex Session Isolator: Open Launcher Config`
   - expected:
     - both commands work
     - no legacy wording appears in warnings or notifications

3. `Setup logging on an already-initialized project`
   - choose a project that already has `.vsc_launcher/logs`
   - run `Codex Session Isolator: Setup Launcher`
   - expected:
     - operation still behaves as before
     - VS Code Output channel shows the flow
     - `.vsc_launcher/logs/extension-YYYYMMDD.log` gains setup-related breadcrumbs
     - breadcrumbs include target scope and completion/failure outcome

4. `Reopen logging`
   - on a project with launcher artifacts and `.vsc_launcher/logs`, run `Codex Session Isolator: Reopen With Launcher`
   - expected:
     - reopen behavior stays unchanged
     - Output channel records the flow
     - project-local `extension-YYYYMMDD.log` records reopen start and outcome

5. `Rollback logging`
   - on a project that already has rollback metadata and `.vsc_launcher/logs`, run `Codex Session Isolator: Rollback Launcher Changes`
   - expected:
     - rollback confirmation and execution behavior stay unchanged
     - Output channel records the flow
     - project-local `extension-YYYYMMDD.log` records rollback target scope, completion summary, and any fallback decision

6. `Early setup failure visibility`
   - provoke a setup failure before launcher artifacts are created, for example by temporarily making PowerShell unavailable in the environment you are testing
   - expected:
     - the failure is still visible in the VS Code Output channel
     - if `.vsc_launcher/logs` does not exist yet, no project-local extension log is created just for this failed pre-setup attempt

7. `Privacy sanity check`
   - inspect the command descriptions/help text surfaced in the extension and helper docs you rely on
   - expected:
     - examples use generic sample paths
     - no host-specific personal paths appear

Known limitations to keep in mind during testing:

- project-local extension breadcrumbs are best-effort and only append when `.vsc_launcher/logs` already exists
- very early setup failures can still be output-channel-only by design
- removing legacy command IDs is a deliberate breaking change for any old private keybindings/tasks that still referenced them
- `Open Launcher Logs` and `Open Launcher Config` remain utility commands and are intentionally hidden from the default Command Palette list unless invoked directly
- this step does not reintroduce backward compatibility for removed legacy commands

No additional automated validation was required for this documentation-only handoff step.

Approval gate:

- wait for user confirmation before moving to Step 7

### Step 7: Final readiness review for commit

Status:

- `Completed`

Purpose:

- confirm the branch is ready for commit after user testing

Planned work:

- summarize delivered scope and validations
- confirm worktree state
- list any remaining gaps

Expected outputs:

- explicit commit-readiness summary

Validation:

- check repository state and test results

Approval gate:

- commit only after user approval

Commit-readiness review:

- `Scope delivered`: redundant setup surface, legacy command IDs, and legacy namespace fallback logic were removed; project-local extension breadcrumbs were added; docs/help text were genericized; tests and changelog were aligned.
- `Automated validation completed in this environment`:
  - `cd extension && npm run compile`
  - `cd extension && npm run test:unit`
- `Known remaining gap`: Windows-specific behaviors referenced by the updated docs/tests were not fully re-executed in this environment.
- `Commit status`: ready to be committed and merged alongside the rollback work.

## Current Status

- idea created
- context review completed
- Step 1 completed: legacy command IDs were removed, the public setup surface was reduced to `Setup Launcher`, and directly affected docs were synced
- Step 2 completed: extension-driven setup, reopen, and rollback flows now append best-effort project-local breadcrumbs under `.vsc_launcher/logs` when that directory exists
- Step 3 completed: user-specific committed paths were replaced with generic examples and relative links
- Step 4 completed: tests, changelog, and consistency docs were aligned with the new command surface and local extension logging
- Step 5 completed: implementation was reviewed against the idea and no blocking mismatch was found
- Step 6 completed: manual test checklist and expectations were prepared for the cleaned command surface and local logging behavior
- Step 7 completed: final readiness was reviewed and the work is ready to be committed and merged with the rollback branch
