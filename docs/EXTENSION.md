# VS Code Extension Guide

## Goal

The extension provides a hybrid UX:

- collect wizard decisions in VS Code UI
- execute the existing launcher wizard backend
- keep generated launcher behavior identical to CLI flow

## Commands

- Primary Command Palette commands:
  - `Codex Session Isolator: Setup Launcher`
  - `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Setup Launcher`
- `Codex Session Isolator: Initialize Launcher`
- `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Open Launcher Logs`
- `Codex Session Isolator: Open Launcher Config`

Recommended fresh-project flow:

1. Run `Codex Session Isolator: Setup Launcher`.
2. Complete wizard prompts.
3. When setup finishes for the current project, the extension asks whether to reopen immediately with the launcher.
4. If you confirm, the current VS Code window closes and the launcher opens a fresh isolated window.

## Settings

- `codexSessionIsolator.debugWizardByDefault` (default: `false`)
- `codexSessionIsolator.closeWindowAfterReopen` (default: `false`)

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
- On Windows, extension prefers `pwsh` (PowerShell 7) and falls back to `powershell.exe` after a startup probe check.
- On Windows, WSL-related prompts are shown only when WSL is available.
- On macOS/Linux, `Reopen With Launcher` first dispatches the launcher through a detached `bash`/`zsh` wrapper, then falls back to direct executable launch and shell invocation, and logs fallback details in the extension output channel.
- On WSL, if a Windows shortcut was created for the project, `Reopen With Launcher` tries launching that shortcut first; if it is unavailable, launcher execution falls back to the Unix launcher path.
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
- Remote WSL launcher runs also isolate the VS Code WSL server per project by using `.vsc_launcher/vscode-agent` as `VSCODE_AGENT_FOLDER`.
- Separate projects can keep separate account/API-key context.
