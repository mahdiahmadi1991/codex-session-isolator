# Trust and Safety Model

## Core guarantees

- Project behavior is local-first and file-system scoped to the selected target root.
- No global shell profile changes are performed.
- Outside launcher flow, default Codex behavior remains unchanged.

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

This allows manual rollback when needed.

## Runtime trust controls (extension)

- Extension actions require VS Code trusted workspace.
- Initialization prompts an explicit confirmation by default.
- Confirmation behavior can be controlled with:
  - `codexProjectIsolator.requireConfirmation`

## CI security controls

- CI build and integration tests on Windows/Linux/macOS.
- Bundled wizard sync verification between `tools/` and `extension/scripts/`.
- Dedicated security workflow for:
  - dependency review (PR)
  - secret scanning
  - PowerShell syntax validation
  - extension dependency audit
  - CodeQL analysis

## Release integrity

Marketplace publish workflow generates:

- packaged VSIX artifact
- SHA-256 checksum (`.vsix.sha256`)

For stable releases, these are attached as release assets for independent verification.
