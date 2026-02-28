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
- Confirm channel version lanes are correct:
  - `pre-release` must always use an odd patch version (`x.y.1`, `x.y.3`, `x.y.5`, ...)
  - `main` / stable must always use an even patch version (`x.y.0`, `x.y.2`, `x.y.4`, ...)
- Never reuse the same numeric version for both Marketplace channels.
- Confirm branch model is followed:
  - `pre-release` receives feature PR merges and auto-publishes pre-release extension builds.
  - Stable promotion uses a `release/*` branch cut from `pre-release`, with the extension version bumped to the next even patch before merging to `main`.
  - `main` receives only stable-ready merges.

## 3) Prepare release branch from pre-release

Create a release branch from the current `pre-release` tip, then bump `extension/package.json` (and `package-lock.json`) to the next even patch version before opening the PR to `main`.

Example:

```bash
git checkout pre-release
git pull --ff-only origin pre-release
git checkout -b release/0.3.10
# bump extension/package.json and extension/package-lock.json to 0.3.10
```

The `main` promotion policy accepts `pre-release` and `release/*` sources, but `release/*` is the standard path because it gives the stable channel its own unique version.

## 4) Commit release-ready changes

```powershell
git add .
git commit -m "chore: prepare release vX.Y.Z"
```

## 5) Push release branch and open stable PR

```powershell
git push origin release/X.Y.Z
```

- Open a PR from `release/X.Y.Z` to `main`.
- Merge only after CI passes.

## 6) Tag and GitHub release

- Create tag only when you need a formal source tag/audit point for stable.
- For manual stable fallback workflow, tag must match `v<extension.version>`.

```powershell
git tag vX.Y.Z
git push origin vX.Y.Z
```

- Create a GitHub Release from tag `vX.Y.Z`.
- Use `CHANGELOG.md` release notes.

## 7) Marketplace publish paths

- Pre-release: automatic on every push/merge to `pre-release`.
- Stable: publishing is automatic on every push/merge to `main`.
- Manual: run workflow `Extension Publish` (`workflow_dispatch`) and choose `stable` or `pre-release`.
- For manual stable publish, run on `main` and provide `release_tag=v<extension.version>`.
- Workflow produces VSIX checksum (`*.vsix.sha256`) as an artifact for every publish run.

## 8) Immediately advance pre-release after a stable release

After the stable PR lands on `main`, open a follow-up PR into `pre-release` that bumps the extension version to the next odd patch.

Example:

- Stable just shipped as `0.3.10`
- Next `pre-release` version must become `0.3.11`

This keeps Marketplace channel metadata deterministic and prevents the stable channel from inheriting stale pre-release metadata for the same numeric version.
