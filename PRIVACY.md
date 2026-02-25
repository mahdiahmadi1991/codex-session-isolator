# Privacy Notice

## Data handling summary

Codex Session Isolator runs locally on your machine and manages project-local launcher files.

- No built-in telemetry is sent by this project.
- No project content is uploaded by project scripts.
- No external service is called by the launcher wizard for project file processing.

## Files this project may create or update

Within the selected target root:

- `vsc_launcher.bat` or `vsc_launcher.sh`
- `.vsc_launcher/` metadata and logs
- `.vscode/settings.json`
- selected `.code-workspace` settings block (when launch target is a workspace)
- `.gitignore` managed block for Codex artifacts
- `.codex/` (project-local Codex state directory)

## Safety backups

Before overwriting managed files, the wizard creates backups in:

- `.vsc_launcher/backups/<timestamp-pid>/`

Restore is manual: copy backed-up files to their original paths.

## Credentials and secrets

- This project does not request your account password.
- Marketplace publishing uses `VSCE_PAT` in GitHub Secrets.
- Keep PATs and API keys out of repository files.
- With launcher isolation, Codex session/auth context is project-local (`.codex`) instead of global/default home.
