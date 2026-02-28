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
- README images use absolute HTTPS URLs (Marketplace-safe rendering).
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

- `push` to `main` -> auto stable publish
- `workflow_dispatch` -> manual publish (`pre-release` or `stable`)
- `push` to `pre-release` -> auto pre-release publish

Stable policy rules:

- Stable publish version is sourced from `extension/package.json`.
- Stable channel must use an even patch version (`x.y.0`, `x.y.2`, ...).
- Pre-release channel must use an odd patch version (`x.y.1`, `x.y.3`, ...).
- The same numeric version must never be reused across both channels.
- Stable git tag MUST match extension version (`v<version>`).
- Manual stable publish MUST run on `main` and pass `release_tag=v<version>`.
- Stable extension manifest MUST not be preview (`preview` omitted or `false`).

Workflow outputs:

- VSIX package artifact
- SHA-256 checksum file (`*.vsix.sha256`)

Required repository secret:

- `VSCE_PAT` (Visual Studio Marketplace PAT with extension publish permissions)

Recommended rollout:

1. Merge feature work into `pre-release` and keep the extension version on an odd patch number.
2. When ready to ship, cut `release/<stable-version>` from `pre-release`.
3. Bump the extension version on the release branch to the next even patch number.
4. Merge the release branch into `main` (push/merge to `main` auto-publishes stable).
5. Immediately bump `pre-release` again to the next odd patch after the stable release lands.
6. Use manual stable `workflow_dispatch` only as fallback (`ref=main`, `release_tag=v<version>`).

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
