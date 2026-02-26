# VS Code Extension Guide

## Goal

The extension provides a hybrid UX:

- collect wizard decisions in VS Code UI
- execute the existing launcher wizard backend
- keep generated launcher behavior identical to CLI flow

## Commands

- `Codex Session Isolator: Setup (Initialize & Reopen)`
- `Codex Session Isolator: Initialize Launcher`
- `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Open Launcher Logs`
- `Codex Session Isolator: Open Launcher Config`

Recommended fresh-project flow:

1. Run `Codex Session Isolator: Setup (Initialize & Reopen)`.
2. Complete wizard prompts.
3. VS Code reopens automatically with generated launcher.

## Settings

- `codexSessionIsolator.debugWizardByDefault` (default: `false`)
- `codexSessionIsolator.closeWindowAfterReopen` (default: `true`)
- `codexSessionIsolator.requireConfirmation` (default: `true`)

## Development

```bash
cd extension
npm install
npm run compile
```

Run Extension Development Host:

1. Open `extension` folder in VS Code.
2. Press `F5`.

## Notes

- Extension requires PowerShell (`powershell` or `pwsh`).
- On Windows, WSL-related prompts are shown only when WSL is available.
- Initialization runs preflight checks before applying changes:
  - verifies target folder exists and is writable
  - inspects managed paths and shows create/reuse/overwrite-with-backup plan
  - requires explicit confirmation when managed files already exist
- Extension wizard default answers on Windows+WSL:
  - Remote WSL launch: `Yes`
  - Codex run in WSL: `Yes`
  - Distro default: Windows default distro
  - Ignore Codex sessions in gitignore: `No`
- Generated files remain project-local (`vsc_launcher.*`, `.vsc_launcher/`, `.codex/` policy).
- Bundled wizard script is synced from `tools/vsc-launcher-wizard.ps1` via `extension/scripts/sync-wizard.mjs`.
- Extension operations require a trusted workspace.
- Wizard creates backups before overwriting managed files under `.vsc_launcher/backups/`.
- Because launcher sessions use project-local `.codex`, chat/session visibility is isolated per project.
- Separate projects can keep separate account/API-key context.
