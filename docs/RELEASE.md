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

## 2) Documentation checks

- Confirm `README.md`, `docs/USAGE.md`, and `docs/TESTING.md` match current launcher behavior.
- Confirm `CHANGELOG.md` contains release notes for the version to publish.

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
