# Issue Drafts (Repository Audit)

> Note: I cannot create GitHub issues directly from this environment, so each item below is written as a ready-to-open issue.

## 1) `readWizardDefaults` silently ignores malformed JSON and hides user config corruption

- **Type:** Bug / Reliability
- **Severity:** Medium
- **Location:** `/extension/src/extension.ts` (function `readWizardDefaults`, catch block)
- **Problem:** When `.vsc_launcher/wizard.defaults.json` is malformed, parsing errors are swallowed and the function quietly returns `{}`. The user gets no warning that saved defaults were ignored.
- **Repro:** Put invalid JSON in `.vsc_launcher/wizard.defaults.json`, run extension initialize flow, observe no warning and defaults reset behavior.
- **Expected:** User should be informed (output channel and/or warning), with graceful fallback.
- **Suggested fix:** Log parse/read error details to extension output channel and optionally show a warning message once.

## 2) Wizard workspace discovery silently skips inaccessible directories

- **Type:** Bug / Observability / UX
- **Severity:** Low-Medium
- **Location:** `/extension/src/extension.ts` (function `findWorkspaceFiles`, `catch { return; }`)
- **Problem:** Directory read failures (`fs.readdir`) are ignored with no diagnostics. In partial-permission trees, workspace detection may be incomplete with no explanation.
- **Repro:** Use a project root containing subfolders without read permission, run initialize flow, compare expected `.code-workspace` candidates vs shown list.
- **Expected:** Failures should be logged so users understand partial scan behavior.
- **Suggested fix:** Append a diagnostic line to output channel for skipped paths and error reason.

## 3) `Ensure-JsonObjectFile` backup path failure is not handled explicitly

- **Type:** Bug / Robustness
- **Severity:** Medium
- **Location:** `/tools/vsc-launcher-wizard.ps1` (function `Ensure-JsonObjectFile`, parse-failure catch)
- **Problem:** On JSON parse failure, code attempts `Copy-Item` to `*.bak` but does not handle copy failures separately (e.g., permission denied / disk issue). This can hide backup failure and reduce recoverability.
- **Repro:** Force invalid JSON in a managed file and run wizard in an environment where backup write fails.
- **Expected:** Backup failure should be surfaced in wizard logs/output.
- **Suggested fix:** Wrap backup copy with explicit error handling and `Write-Info`/`Fail` strategy.

## 4) Launcher reopen path executes generated launcher without integrity guard

- **Type:** Security Hardening
- **Severity:** Medium
- **Location:** `/extension/src/extension.ts` (function `reopenWithLauncher`)
- **Problem:** Extension executes `vsc_launcher.bat`/`.sh` directly when present. While workspace trust is checked, there is no extra integrity signal (e.g., managed marker/checksum) before execution.
- **Threat model note:** In compromised local workspace scenarios, this increases risk of arbitrary command execution via replaced launcher file.
- **Expected:** Safer execution path with basic provenance/integrity validation.
- **Suggested fix:** Validate launcher provenance (managed header marker and/or config-linked checksum) before running.

## 5) Wizard process input path lacks explicit handling for non-writable stdin edge cases

- **Type:** Bug / Edge-case handling
- **Severity:** Low
- **Location:** `/extension/src/extension.ts` (function `runWizardProcess`)
- **Problem:** Responses are written only if `child.stdin.writable`; otherwise flow continues without explicit error, potentially leaving process waiting for interactive input.
- **Expected:** Non-writable stdin should fail fast with clear error in output channel.
- **Suggested fix:** Add explicit else-path logging + resolve non-zero exit state when response injection is unavailable.
