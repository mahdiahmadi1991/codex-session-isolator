# Codex Session Isolator

![Codex Session Isolator Hero](https://raw.githubusercontent.com/mahdiahmadi1991/codex-session-isolator/main/extension/media/hero.png)

[![CI](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/ci.yml/badge.svg)](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/ci.yml)
[![Security](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/security.yml/badge.svg)](https://github.com/mahdiahmadi1991/codex-session-isolator/actions/workflows/security.yml)
[![VS Code](https://img.shields.io/badge/VS%20Code-1.95%2B-007ACC?logo=visualstudiocode)](https://code.visualstudio.com/)

Project-scoped launcher setup for isolated Codex sessions in VS Code.

This extension gives you a guided VS Code flow for creating, reopening, and rolling back project-local launcher files. It keeps Codex session state scoped to the selected project by driving the same launcher backend used by the CLI helpers.

## Why trust this extension

- Local-first: it does not upload project files or add telemetry.
- Project-scoped: generated artifacts stay inside the selected project.
- Reversible: setup creates backups and records rollback metadata for the latest setup.
- Bounded: rollback targets launcher-managed changes only unless you explicitly opt into `.codex` runtime cleanup.

## Tested environments

- Covered by automated CI on Windows, Linux, and macOS for the repository's supported launcher and extension flows.
- Manually validated on WSL-backed project targets for setup and rollback behavior.
- Environments outside those validated paths should be considered best-effort until they are explicitly added to the test matrix.

## What you can do

- Set up launcher files inside the selected project root.
- Reopen the current project through the generated launcher.
- Roll back the latest launcher-managed setup.
- Open launcher logs or launcher config when you need to inspect behavior.

## Commands

- Primary Command Palette commands:
  - `Codex Session Isolator: Setup Launcher`
  - `Codex Session Isolator: Reopen With Launcher`
  - `Codex Session Isolator: Rollback Launcher Changes`
- Utility commands:
  - `Codex Session Isolator: Open Launcher Logs`
  - `Codex Session Isolator: Open Launcher Config`

## What changes when launched through the generated launcher

- `CODEX_HOME` is set to `<project>/.codex` for that session.
- Default/global Codex behavior remains unchanged outside launcher flow.
- Chat/session state is isolated per project, so history from other Codex homes is not shown.
- Different project roots can keep separate Codex account/API-key context.

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

## Rollback behavior

- `Rollback Launcher Changes` works for `Current project` or `Another project`.
- Rollback preserves user edits in managed files where possible and only removes launcher-owned artifacts automatically.
- If the target project has removable `.codex` runtime data, the extension asks whether to remove it too. The default answer is `No`, and `.codex/config.toml` is preserved.
- If native Trash/Recycle Bin is unavailable for a launcher-owned path or opted-in `.codex` runtime data, rollback stops by default and asks whether to continue with permanent deletion.

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

## WSL notes

Default wizard answers on Windows + WSL are context-aware:

- Local Windows path: Remote WSL launch `No`
- WSL UNC path (`\\wsl$\...`): Remote WSL launch `Yes`
- Codex run in WSL: prompted only when Remote WSL launch is `Yes` (default `Yes`)
- Distro selection is skipped when the target path already identifies the distro (for example `\\wsl$\Ubuntu-24.04\...`); otherwise the default is the Windows default distro
- Track Codex session history in git: `No`

If your target is under `\\wsl$\...`, keep Remote WSL launch enabled to avoid mixed Windows/WSL context warnings in VS Code.
For WSL-hosted targets, wizard can generate a Windows shortcut `Open <project>.lnk` and lets you choose location (`Project root`, `Desktop`, `Start Menu`, or `Custom path`).
Remote WSL launches also isolate the VS Code WSL server per project by using `.vsc_launcher/vscode-agent` as `VSCODE_AGENT_FOLDER`.

## Cleanup/Uninstall

Preferred cleanup for one project:

1. Run `Codex Session Isolator: Rollback Launcher Changes`.
2. Answer only the rollback questions that are relevant for that target and environment.

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
