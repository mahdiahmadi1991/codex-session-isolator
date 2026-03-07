# Rollback Launcher Changes

## Goal

Add a new rollback capability that reverts launcher-related changes previously applied to a consumer project.

The rollback flow must:

- work from the VS Code extension and use the same target-selection model as setup
- support `Current project` and `Another project`
- restore or remove only launcher-managed changes
- avoid touching unrelated user files beyond the wizard's managed surface
- preserve user trust by being explicit, local-only, and reversible where possible

## Scope

Rollback should target the same managed surface currently owned by the wizard:

- root launcher files:
  - `vsc_launcher.bat`
  - `vsc_launcher.sh`
- optional Windows shortcut generated for WSL-hosted targets:
  - `Open <project>.lnk`
- metadata directory:
  - `.vsc_launcher/`
- VS Code settings file:
  - `.vscode/settings.json`
- selected workspace file settings block when the launch target is a `.code-workspace`
- wizard-managed block inside `.gitignore`
- generated workspace file created by the wizard when no workspace existed and the wizard synthesized `<project-name>.code-workspace`

Rollback should not touch:

- `.codex/`
- user source files
- unrelated settings in `.vscode/settings.json` or workspace files beyond what the wizard previously changed
- any non-managed `.gitignore` content outside the managed block
- globally installed VS Code settings or extensions

## Product Behavior

### New command

Add a new extension command:

- `Codex Session Isolator: Rollback Launcher Changes`

Command palette visibility:

- make it a primary visible command alongside setup/reopen

### Target selection

Reuse the existing target-selection UX:

- `Current project (recommended)`
- `Another project`

Behavior:

- `Current project`: apply rollback to the active project
- `Another project`: let the user choose a different target folder and do not close/reopen the current VS Code window

### Confirmation UX

Rollback is more destructive than setup, so the user must get a clear confirmation summary before execution.

Suggested modal confirmation:

- title:
  - `Rollback launcher changes for this project?`
- detail summary:
  - target root
  - whether backup data was found
  - whether launcher files will be deleted
  - whether settings/workspace/gitignore will be restored from backup or cleaned surgically

Suggested actions:

- `Rollback`
- `Cancel`

### Completion UX

After success:

- for current project:
  - show summary notification
  - do not auto-close or reopen unless a future product decision explicitly wants that
- for another project:
  - show summary report modal similar to external-target setup completion

### Failure UX

Rollback should fail closed if it cannot safely determine what to do.

Examples:

- `.vsc_launcher/` missing and no rollback manifest/backup exists
- latest backup session cannot be parsed
- a required restore source is missing

Error messaging should clearly say whether the failure happened because:

- no managed artifacts were found
- rollback metadata is missing
- backup data is incomplete
- file restore/delete failed

## Technical Design

### Core principle

Prefer deterministic rollback based on explicit metadata created during launcher setup, not on best-effort filesystem guessing alone.

Current backup coverage is helpful but not enough by itself for a high-confidence rollback feature because it does not fully answer:

- which files were newly created vs previously existing
- which workspace file was selected at setup time
- whether a workspace file was wizard-generated
- whether a Windows shortcut was generated outside project root

### New metadata file

Introduce a new metadata file under `.vsc_launcher/`, for example:

- `.vsc_launcher/rollback.manifest.json`

Write/update it at the end of successful launcher generation.

Suggested contents:

```json
{
  "version": 1,
  "targetRoot": "...",
  "launchMode": "workspace|folder",
  "workspaceRelativePath": "sample.code-workspace",
  "generatedWorkspaceRelativePath": "my-project.code-workspace",
  "generatedWorkspaceWasCreated": true,
  "launcherFiles": ["vsc_launcher.bat"],
  "metadataDir": ".vsc_launcher",
  "windowsShortcut": {
    "enabled": true,
    "location": "projectRoot|desktop|startMenu|custom",
    "projectRelativePath": "Open Project.lnk",
    "absoluteWindowsPath": "..."
  },
  "managedFiles": {
    "vscodeSettings": {
      "path": ".vscode/settings.json",
      "hadBackup": true
    },
    "workspaceSettings": {
      "path": "sample.code-workspace",
      "hadBackup": true
    },
    "gitignore": {
      "path": ".gitignore",
      "hadBackup": true
    },
    "launcherConfig": {
      "path": ".vsc_launcher/config.json",
      "hadBackup": false
    }
  },
  "latestBackupSessionId": "20260307-142201-440",
  "createdAtUtc": "...",
  "updatedAtUtc": "..."
}
```

Notes:

- absolute Windows shortcut path is needed because the shortcut may live outside project root
- backup-presence flags help distinguish `restore` vs `delete`
- generated workspace metadata avoids accidentally deleting a pre-existing workspace file

### Rollback strategy

The rollback algorithm should work in this order:

1. Resolve target root.
2. Load rollback manifest.
3. Resolve latest referenced backup session under `.vsc_launcher/backups/`.
4. Build a rollback plan in memory:
   - paths to restore from backup
   - paths to delete because they were generated and had no prior backup
   - external shortcut path to remove if present
5. Confirm with the user.
6. Execute rollback:
   - restore backed-up files first
   - remove generated launcher files
   - remove generated workspace file only if manifest says wizard created it
   - remove project-root shortcut if generated
   - remove external shortcut if generated
   - remove `.vsc_launcher/` last
7. Report result.

### Restore semantics by file type

#### `.vscode/settings.json`

If backup exists:

- restore the entire previous file from backup

If no backup exists:

- remove the file only if rollback manifest says the wizard created it
- otherwise surgically remove only launcher-managed keys:
  - `chatgpt.runCodexInWindowsSubsystemForLinux`
  - `chatgpt.openOnStartup` only if it was written by wizard and not present before
  - `chatgpt.cliExecutable` only if it points to `.vsc_launcher/codex-wsl-wrapper.sh`

Recommended approach:

- store enough metadata in rollback manifest to know whether `.vscode/settings.json` existed before setup
- if it did not exist, delete it on rollback
- if it existed, prefer full-file restore from backup

#### Workspace file

If backup exists:

- restore full workspace file from backup

If no backup exists and manifest says wizard created the workspace:

- delete that generated workspace file

If no backup exists and workspace pre-existed:

- this should be treated as invalid manifest state and fail closed

#### `.gitignore`

If backup exists:

- restore full `.gitignore` from backup

If no backup exists:

- remove only the managed block from current `.gitignore`

This keeps rollback aligned with trust boundaries and avoids user-content loss.

#### Launcher files and generated scripts

Delete if present:

- `vsc_launcher.bat`
- `vsc_launcher.sh`
- `.vsc_launcher/runner.ps1`
- `.vsc_launcher/config.json`
- `.vsc_launcher/config.env`
- `.vsc_launcher/codex-wsl-wrapper.sh`
- `.vsc_launcher/vscode-user-data/`
- `.vsc_launcher/vscode-agent/`
- `.vsc_launcher/logs/`
- `.vsc_launcher/backups/`
- rollback manifest itself

Because `.vsc_launcher/` is fully owned by the tool, removing the directory at the end is acceptable.

#### Windows shortcut

If generated:

- delete the shortcut file from project root or external path

If the shortcut path cannot be found:

- warn but do not fail the entire rollback

## Extension Changes

### Commands and registration

Add new command IDs:

- `codexSessionIsolator.rollback`
- `codexProjectIsolator.rollback` as legacy alias

Update:

- `extension/package.json`
- `extension/src/extension.ts`

### Target-selection flow

Reuse:

- `pickOperationTarget()`
- external-target completion pattern

Add a new handler:

- `rollbackLauncherCommand(context, output)`

### Project inspection

Add helper(s) to inspect rollback eligibility:

- detect `.vsc_launcher/rollback.manifest.json`
- fallback detect `.vsc_launcher/` + backups
- detect existing launcher files

### Rollback execution

Two implementation options:

1. implement rollback directly inside the extension in TypeScript
2. implement rollback in the PowerShell wizard/backend and have extension call it

Recommended approach:

- implement rollback in PowerShell backend and let extension remain a UX layer

Reason:

- file restore/delete semantics are already concentrated in PowerShell
- Windows shortcut deletion and backup-path handling are already better aligned there
- it keeps extension behavior aligned with CLI/backend behavior

## Backend Changes

### Preferred implementation model

Extend `tools/vsc-launcher-wizard.ps1` with rollback mode, for example:

- `-Rollback`
- `-TargetPath`

Possible entry points:

- `tools/vsc-launcher.ps1 --rollback`
- `tools/vsc-launcher.sh --rollback`
- extension command calls bundled wizard with rollback mode

This keeps one source of truth for both setup and rollback.

### New functions

Expected new backend functions:

- `Get-RollbackManifest`
- `Save-RollbackManifest`
- `Get-LatestBackupSession`
- `Get-RollbackPlan`
- `Invoke-RollbackPlan`
- `Remove-ManagedGitIgnoreBlock`
- `Restore-FileFromBackup`
- `Remove-GeneratedWorkspaceIfOwned`

### Manifest creation timing

Save rollback manifest only after successful generation of launcher artifacts and managed settings.

If generation fails midway:

- do not write manifest
- leave only backups/logs for manual inspection

## CLI / Helper UX

The shell/PowerShell helper entry points should expose rollback for CLI users too.

Suggested examples:

```powershell
.\tools\vsc-launcher.ps1 --rollback "C:\path\to\project"
```

```bash
./tools/vsc-launcher.sh --rollback "/path/to/project"
```

This avoids making rollback extension-only.

## Data Safety Rules

- never touch `.codex/`
- never restore or delete files outside the manifest/managed surface, except the explicitly generated external Windows shortcut
- fail closed if ownership is ambiguous
- use backup restore in preference to current-file mutation whenever backup exists
- delete `.vsc_launcher/` only after all other restore operations succeed

## Edge Cases

### No manifest, but `.vsc_launcher/` exists

Fallback behavior:

- inspect latest backup folder and managed artifacts
- show user a warning that rollback is best-effort

Preferred first version:

- do not implement best-effort fallback yet
- require manifest for rollback
- show a clear message for legacy setups

Rationale:

- safer
- easier to reason about
- avoids accidental deletion of user content

### User edited files after setup

If backup exists:

- rollback restores backed-up pre-setup state, intentionally discarding post-setup edits in those managed files

This is acceptable only because:

- the rollback command is explicit
- confirmation should say restore uses the pre-setup backup

### Multiple setup runs

Rollback should revert the latest known applied setup, not every historical setup ever created.

Manifest should therefore always point to the latest backup session relevant to current launcher state.

### Missing external shortcut

Warn only. Do not fail full rollback.

### Legacy projects without rollback manifest

First implementation should detect and report:

- `This project was initialized before rollback metadata existed. Automatic rollback is not available for this target.`

Optional later enhancement:

- add best-effort legacy rollback

## Test Plan

### Windows integration

Add cases for:

1. rollback after local setup with existing `.gitignore`
2. rollback after setup that created `.vscode/settings.json`
3. rollback after setup that modified pre-existing `.vscode/settings.json`
4. rollback after setup that modified workspace settings
5. rollback after generated workspace creation
6. rollback after WSL shortcut generation in project root
7. rollback after WSL shortcut generation outside project root
8. repeated setup -> rollback -> setup round trip
9. rollback on target with no manifest
10. rollback on another project target from extension flow

Assertions:

- launcher files removed
- `.vsc_launcher/` removed
- `.gitignore` restored or managed block removed
- workspace/settings restored
- generated workspace deleted only when owned by wizard
- shortcut removed when owned by wizard

### Linux/macOS integration

Add cases for:

1. rollback after Unix launcher generation
2. rollback after wizard-created workspace
3. rollback after tracked-history mode setup
4. no-manifest rollback failure path

### Extension unit / behavior tests

Add coverage for:

- new rollback command registration
- target selection reuse
- completion report for `Another project`
- graceful error when manifest is missing

## Suggested Delivery Plan

### Phase 1

- add rollback manifest writing during setup
- add backend rollback mode
- add CLI helper flags

### Phase 2

- add extension rollback command and target-selection flow
- add user confirmation/reporting

### Phase 3

- add automated tests
- sync docs
- package and local-install updated extension

## Explicit Assumptions

- rollback is for launcher-managed changes only
- `.codex/` contents are never rolled back
- first implementation can require rollback metadata and reject legacy setups without it
- restore of managed files should prefer exact backup restore over partial mutation

## Recommended First Implementation Decision

Keep v1 strict:

- require rollback manifest
- rollback only latest setup state
- do not attempt legacy best-effort cleanup

That gives the safest foundation. After that, if needed, legacy rollback support can be added as a second iteration.
