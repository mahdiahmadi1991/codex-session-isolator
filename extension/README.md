# Codex Session Isolator

Per-project Codex session isolation for VS Code targets (workspaces or folders).

![Codex Session Isolator Hero](https://raw.githubusercontent.com/mahdiahmadi1991/codex-session-isolator/main/extension/media/hero.png)

## Why this extension

This extension gives you a guided VS Code UX for creating and using project-scoped launcher files.
It keeps Codex session state isolated per project by driving the existing launcher backend.

## What it does

- Initializes launcher files inside the selected project root.
- Reopens VS Code through the generated launcher.
- Rolls back launcher-managed changes from the latest setup.
- Opens launcher logs for debugging.
- Opens launcher config quickly for inspection.

When launched through generated launcher:

- `CODEX_HOME` is set to `<project>/.codex` for that session.
- Default/global behavior remains unchanged outside launcher flow.
- Chat/session state is isolated per project, so global/default history from other projects is not shown.
- Different project roots can use different Codex account/API-key context.

## Commands

- Primary Command Palette commands:
- `Codex Session Isolator: Setup Launcher`
- `Codex Session Isolator: Reopen With Launcher`
- `Codex Session Isolator: Rollback Launcher Changes`
- Utility commands (kept available but hidden from the default Command Palette list):
- `Codex Session Isolator: Open Launcher Logs`
- `Codex Session Isolator: Open Launcher Config`

## Quick Start

1. Install extension `2ma.codex-session-isolator` from VS Code Marketplace.
2. Open your project folder/workspace in VS Code.
3. Run `Codex Session Isolator: Setup Launcher`.
4. At command start, choose target scope:
   - `Current project (recommended)`
   - `Another project`
5. If `Another project` is selected, extension applies setup to that folder and shows completion report without reopening/closing current window.
6. If `Current project` is selected, the extension asks whether to reopen with the generated launcher and closes the current window only after you confirm.
7. Verify in terminal:
   - Windows PowerShell: `echo $env:CODEX_HOME`
   - bash/zsh: `echo "$CODEX_HOME"`

Expected value:

- `<project-root>/.codex` (or Linux path equivalent in WSL/Unix modes)

## Release channels

- Stable channel: published from `main`.
- Pre-release channel: published from `pre-release`.
- Stable uses even patch versions (`x.y.0`, `x.y.2`, ...).
- Pre-release uses odd patch versions (`x.y.1`, `x.y.3`, ...).
- The same numeric version is never reused across both channels.
- If a newer pre-release build exists in Marketplace, VS Code can still show a `Preview` badge on the extension details page even when the installed build is a stable version or a locally installed VSIX.

Install pre-release build from VS Code:

1. Open extension page for `2ma.codex-session-isolator`.
2. Open Manage menu (gear icon).
3. Choose `Install Pre-Release Version` (or `Switch to Pre-Release Version`).

CLI alternative:

```bash
code --install-extension 2ma.codex-session-isolator --pre-release
```

Default wizard answers on Windows + WSL are context-aware:

- Local Windows path: Remote WSL launch `No`
- WSL UNC path (`\\wsl$\...`): Remote WSL launch `Yes`
- Codex run in WSL: prompted only when Remote WSL launch is `Yes` (default `Yes`)
- Distro selection is skipped when the target path already identifies the distro (for example `\\wsl$\Ubuntu-24.04\...`); otherwise the default is the Windows default distro
- Track Codex session history in git: `No`

If your target is under `\\wsl$\...`, keep Remote WSL launch enabled to avoid mixed Windows/WSL context warnings in VS Code.
For WSL-hosted targets, wizard can generate a Windows shortcut `Open <project>.lnk` and lets you choose location (`Project root`, `Desktop`, `Start Menu`, or `Custom path`).
Remote WSL launches also isolate the VS Code WSL server per project by using `.vsc_launcher/vscode-agent` as `VSCODE_AGENT_FOLDER`.

Rollback notes:

- `Rollback Launcher Changes` works for `Current project` or `Another project`.
- Rollback preserves user edits in managed files where possible and only removes launcher-owned artifacts automatically.
- If the target project has removable `.codex` runtime data, the extension asks whether to remove it too. The default answer is `No`, and `.codex/config.toml` is preserved.
- If native Trash/Recycle Bin is unavailable for a launcher-owned path or opted-in `.codex` runtime data, rollback stops by default and asks whether to continue with permanent deletion.

## Cleanup/Uninstall

Preferred cleanup for one project:

1. Run `Codex Session Isolator: Rollback Launcher Changes`.
2. Confirm the summary for the target project.

Manual cleanup fallback:

1. Delete launcher files from project root:
   - `vsc_launcher.bat` (Windows) or `vsc_launcher.sh` (Linux/macOS)
   - `Open <project>.lnk` (only for WSL-hosted targets when enabled)
2. Delete `.vsc_launcher/` (includes logs/config/backups).
3. Remove managed block in `.gitignore`:
   - from `# >>> codex-session-isolator >>>`
   - to `# <<< codex-session-isolator <<<`
4. Optional: remove extension-managed settings if no longer needed:
   - `chatgpt.runCodexInWindowsSubsystemForLinux`
   - `chatgpt.openOnStartup`
   - `chatgpt.cliExecutable` (only if it points to `.vsc_launcher/codex-wsl-wrapper.sh`)
5. Optional: delete project `.codex/` only if you do not need that project's isolated session history/state.

## Requirements

- VS Code 1.95+
- PowerShell available (`powershell` or `pwsh`)
- Optional for WSL modes: WSL installed and configured

## Settings

- `codexSessionIsolator.debugWizardByDefault`
- `codexSessionIsolator.closeWindowAfterReopen`

## Security and Privacy

- The extension does not send telemetry and does not upload your project files.
- All launcher generation is local and runs through a bundled PowerShell script in this extension package.
- The extension requires a trusted workspace before running launcher or wizard scripts.
- By default, the extension asks for explicit confirmation before initialization.
- Before overwriting managed files, the wizard creates safety backups under:
  - `<project>/.vsc_launcher/backups/<timestamp-pid>/`

## Troubleshooting

- `PowerShell was not found`:
  install `pwsh` (PowerShell 7) or `powershell.exe`, then run `Setup Launcher` again.
- `Launcher file not found in target root`:
  run `Setup Launcher` first.
- WSL prompts/options are missing:
  run `wsl --status`; if unavailable, use local mode or install/configure WSL.
- Permission/write errors:
  check folder write access and rerun. Existing managed files are backed up under `.vsc_launcher/backups/`.
- Always check logs:
  1. VS Code Output channel: `Codex Session Isolator`
  2. Project logs: `.vsc_launcher/logs` (`launcher-*.log`, wizard logs, and best-effort `extension-YYYYMMDD.log` breadcrumbs when the logs directory already exists)

## Source

- Repository: https://github.com/mahdiahmadi1991/codex-session-isolator
- Issues: https://github.com/mahdiahmadi1991/codex-session-isolator/issues
- Discussions: https://github.com/mahdiahmadi1991/codex-session-isolator/discussions

## Development

```bash
cd extension
npm install
npm run compile
```

Press `F5` in VS Code (from `extension` folder) to run Extension Development Host.
