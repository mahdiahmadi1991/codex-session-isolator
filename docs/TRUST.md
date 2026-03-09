# Trust and Safety Model

## Core guarantees

- Project behavior is local-first and file-system scoped to the selected target root.
- No global shell profile changes are performed.
- Outside launcher flow, default Codex behavior remains unchanged.
- Public docs and Marketplace-facing content should state validated environments explicitly and avoid implying broader compatibility than the current matrix supports.

## Session and credential isolation

- Launcher runs use target-local `.codex` as `CODEX_HOME`.
- This means project launcher sessions do not show global/default history from other Codex homes.
- Different projects can maintain separate account/API-key context.

## Managed file boundaries

The wizard only manages known files and folders:

- `vsc_launcher.*`
- `.vsc_launcher/*`
- `.vscode/settings.json`
- selected workspace file settings
- managed block in `.gitignore`

## Backup and recovery

Before overwriting managed files, backups are created under:

- `.vsc_launcher/backups/<timestamp-pid>/`

The latest setup also records rollback ownership in `.vsc_launcher/rollback.manifest.json` so launcher-managed changes can be rolled back without guessing across unrelated user files.

## Runtime trust controls (extension)

- Extension actions require VS Code trusted workspace.
- Rollback only asks the follow-up questions that are actually needed for the selected target and environment.
- Extension operation logs stay local: flow breadcrumbs remain in the VS Code output channel and, when a project already has `.vsc_launcher/logs`, are also appended there as best-effort local log entries.
- Extension logging remains non-blocking and does not create remote uploads, telemetry, or credential-bearing secret dumps.

## CI security controls

- CI build and integration tests on Windows/Linux/macOS.
- Bundled wizard sync verification between `tools/` and `extension/scripts/`.
- Dedicated security workflow for:
  - dependency review (PR)
  - secret scanning
  - PowerShell syntax validation
- extension dependency audit
- CodeQL analysis

## Validation boundaries

- Current confidence is highest for the flows covered by CI on Windows, Linux, and macOS, plus manual validation on WSL-backed targets.
- Behavior outside that validated matrix should be treated as best-effort, not as an implicit compatibility guarantee.
- If a new platform combination matters for release confidence, add it to `docs/TESTING.md` and validate it before advertising it as covered.

## Release integrity

Marketplace publish workflow generates:

- packaged VSIX artifact
- SHA-256 checksum (`.vsix.sha256`)

For stable releases, these are attached as release assets for independent verification.
