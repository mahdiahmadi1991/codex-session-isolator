# Release Guide

## 1) Pre-release checks

Run from repository root:

```powershell
git status -sb
./tests/Test-Windows.ps1
```

Linux test checks (WSL/Linux/macOS):

```bash
chmod +x tests/test-linux.sh
./tests/test-linux.sh
```

Security checks:

```powershell
# workflow-level checks run in CI:
# - .github/workflows/security.yml
```

## 2) Documentation checks

- Confirm `README.md`, `docs/USAGE.md`, and `docs/TESTING.md` match current launcher behavior.
- Confirm `CHANGELOG.md` contains release notes for the version to publish.
- Prepare release notes from `docs/RELEASE_TEMPLATE.md`.

## 2.1) Extension marketplace checks

- Confirm `extension/package.json` version is set for target stable release.
- Confirm extension id is `2ma.codex-session-isolator`.
- Confirm repository secret `VSCE_PAT` is configured.
- Confirm branch model is followed:
  - `pre-release` receives feature PR merges and auto-publishes pre-release extension builds.
  - `main` receives only stable-ready merges.

## 3) Commit release-ready changes

```powershell
git add .
git commit -m "chore: prepare release vX.Y.Z"
```

## 4) Push stable branch

```powershell
git push origin main
```

## 5) Optional: tag and GitHub release

- Create tag only when you need a formal source tag/audit point for stable.
- For manual stable fallback workflow, tag must match `v<extension.version>`.

```powershell
git tag vX.Y.Z
git push origin vX.Y.Z
```

- Create a GitHub Release from tag `vX.Y.Z`.
- Use `CHANGELOG.md` release notes.

## 6) Marketplace publish paths

- Pre-release: automatic on every push/merge to `pre-release`.
- Stable: publishing is automatic on every push/merge to `main`.
- Manual: run workflow `Extension Publish` (`workflow_dispatch`) and choose `stable` or `pre-release`.
- For manual stable publish, run on `main` and provide `release_tag=v<extension.version>`.
- Workflow produces VSIX checksum (`*.vsix.sha256`) as an artifact for every publish run.
