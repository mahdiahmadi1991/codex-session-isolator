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

## 2.1) Extension marketplace checks

- Confirm `extension/package.json` version is set for target stable release.
- Confirm extension id is `2ma.codex-project-isolator`.
- Confirm repository secret `VSCE_PAT` is configured.
- Optional auto pre-release toggle: repository variable `MARKETPLACE_AUTO_PUBLISH_MAIN=true`.

## 3) Commit and tag

```powershell
git add .
git commit -m "chore: prepare release vX.Y.Z"
git tag vX.Y.Z
```

## 4) Push

```powershell
git push origin main
git push origin vX.Y.Z
```

## 5) GitHub release

- Create a GitHub Release from tag `vX.Y.Z`.
- Use `CHANGELOG.md` release notes.

## 6) Marketplace publish paths

- Stable: publishing is automatic on `release.published` via `.github/workflows/extension-publish.yml`.
- Manual: run workflow `Extension Publish` (`workflow_dispatch`) and choose `stable` or `pre-release`.
- Continuous pre-release on `main`: enable `MARKETPLACE_AUTO_PUBLISH_MAIN=true`.
- Workflow also produces VSIX checksum (`*.vsix.sha256`); publish these files with stable release assets.
