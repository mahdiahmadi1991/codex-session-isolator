# VS Code Marketplace Preparation

This checklist prepares the `extension/` package for publishing.

Current extension identifier:

- `2ma.codex-session-isolator`

## Metadata checklist

- `extension/package.json`
  - `publisher`
  - `name`, `displayName`, `description`
  - `icon`
  - `repository`, `homepage`, `bugs`, `qna`
  - `keywords`, `categories`
  - `license`
- `extension/README.md` is user-facing and complete.
- `extension/CHANGELOG.md` exists.
- `extension/LICENSE` exists.

## Build and package

```bash
cd extension
npm install
npm run compile
npm run package
```

Output:

- `extension/codex-session-isolator-<version>.vsix`

## Local install test

```bash
code --install-extension extension/codex-session-isolator-<version>.vsix --force
code --list-extensions | findstr codex-session-isolator
```

## Manual smoke test

1. Run `Codex Session Isolator: Initialize Launcher`.
2. Run `Codex Session Isolator: Reopen With Launcher`.
3. Verify project-local `CODEX_HOME`.
4. Check `.vsc_launcher/logs`.

## Publish (when ready)

```bash
cd extension
npx @vscode/vsce publish
```

Alternative explicit version bump:

```bash
npx @vscode/vsce publish minor
```

Prerequisites:

- Azure DevOps / Visual Studio Marketplace publisher access
- `vsce` authenticated (`vsce login <publisher>`)

## GitHub Actions publish automation

Workflow file:

- `.github/workflows/extension-publish.yml`
- `.github/workflows/security.yml` (ongoing security checks)

Supported triggers:

- `release.published` -> stable publish
- `workflow_dispatch` -> manual publish (`pre-release` or `stable`)
- `push` to `pre-release` -> auto pre-release publish

Workflow outputs:

- VSIX package artifact
- SHA-256 checksum file (`*.vsix.sha256`)
- On stable release event, VSIX and checksum are attached to the GitHub release

Required repository secret:

- `VSCE_PAT` (Visual Studio Marketplace PAT with extension publish permissions)

Recommended rollout:

1. Merge feature work into `pre-release` and validate automatic pre-release publishing.
2. Validate manual fallback with `workflow_dispatch` in `pre-release` mode.
3. Promote to `main` only for stable-ready commits.
   - enforced policy: only PRs from `pre-release` are accepted to `main`
   - emergency exception: label `allow-main-hotfix` and then sync `main` back to `pre-release`
4. Publish stable via GitHub Release tag matching extension version (`v<version>`).

## Integrity verification (consumer side)

After downloading release assets:

Windows PowerShell:

```powershell
Get-FileHash .\codex-session-isolator-<version>.vsix -Algorithm SHA256
Get-Content .\codex-session-isolator-<version>.vsix.sha256
```

Linux/macOS:

```bash
sha256sum codex-session-isolator-<version>.vsix
cat codex-session-isolator-<version>.vsix.sha256
```
