# Release Guide

## 0) Version discipline (mandatory)

- Single source of truth for extension release version: `extension/package.json`.
- Stable git tag MUST equal extension version in `vX.Y.Z` format.
  - Example: if `extension/package.json` is `0.3.3`, stable tag MUST be `v0.3.3`.
- Stable Marketplace publish MUST use a non-preview extension manifest
  (`preview` omitted or `false`).

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
- Confirm `extension/package.json` does not mark stable as preview (`preview` is omitted or `false`).

## 2.2) Git graph note (squash merge behavior)

- This repository uses squash merges for promotion/sync PRs.
- Because of squash commits, `main` and `pre-release` can look diverged in commit graph (different commit SHAs) even when file content is identical.
- Treat content diff as source of truth, not graph shape.

Quick verification:

```powershell
git fetch origin --prune
git diff --name-status origin/main..origin/pre-release
git diff --name-status origin/pre-release..origin/main
```

If both diff commands return no files, branches are content-aligned and this state is expected.

## 3) Prepare release commit (pre-release)

```powershell
git add .
git commit -m "chore: prepare release vX.Y.Z"
```

## 4) Promote to main

```powershell
# create PR: pre-release -> main
```

## 5) Tag from main after promotion merge

```powershell
git switch main
git pull
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

## 6) Stable publish paths

- Preferred: create/publish GitHub Release from tag `vX.Y.Z` (auto stable publish).
- Manual fallback: run `Extension Publish` with:
  - `channel=stable`
  - `ref=main`
  - `release_tag=vX.Y.Z` (must exist and must equal extension version tag)

## 7) Pre-release publish path

- Pre-release: automatic on every push/merge to `pre-release`.

## 8) GitHub release notes and assets

- Create a GitHub Release from tag `vX.Y.Z`.
- Use `CHANGELOG.md` release notes.
- Stable workflow attaches VSIX checksum assets on `release.published`.
