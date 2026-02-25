# Release Guide

## 1) Pre-release checks

Run from repository root:

```powershell
git status -sb
powershell -NoProfile -Command "$files=@('launchers/CodexSessionIsolator.ps1','tools/New-VscLauncherWizard.ps1'); foreach($f in $files){$errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$errors)|Out-Null; if($errors){$errors|ForEach-Object{Write-Error ($f + ': ' + $_.Message)}; exit 1}}"
```

Dry-run checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launchers\CodexSessionIsolator.ps1 -TargetPath "$PWD" -DryRun
cmd /c "call launchers\codex-session-isolator.bat %CD% -DryRun"
```

Linux shell syntax check (run in Linux/macOS or WSL):

```bash
bash -n launchers/codex-session-isolator.sh
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
