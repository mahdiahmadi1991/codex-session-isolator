#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WIZARD_HELPER="$REPO_ROOT/tools/vsc-launcher.sh"
WIZARD_PS1="$REPO_ROOT/tools/vsc-launcher.ps1"
WIZARD_SCRIPT_PS1="$REPO_ROOT/tools/vsc-launcher-wizard.ps1"
CANONICAL_LAUNCHER="$REPO_ROOT/launchers/codex-session-isolator.sh"

assert_contains() {
  local text="$1"
  local expected="$2"
  local message="$3"
  if [[ "$text" != *"$expected"* ]]; then
    echo "Assertion failed: $message"
    echo "Expected to contain: $expected"
    echo "Actual: $text"
    exit 1
  fi
}

assert_file_exists() {
  local file_path="$1"
  local message="$2"
  if [[ ! -e "$file_path" ]]; then
    echo "Assertion failed: $message"
    echo "Missing path: $file_path"
    exit 1
  fi
}

assert_file_missing() {
  local file_path="$1"
  local message="$2"
  if [[ -e "$file_path" ]]; then
    echo "Assertion failed: $message"
    echo "Unexpected path: $file_path"
    exit 1
  fi
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" -ne "$expected" ]]; then
    echo "Assertion failed: $message"
    echo "Expected exit code: $expected"
    echo "Actual exit code: $actual"
    exit 1
  fi
}

is_wsl_runtime() {
  [[ -n "${WSL_DISTRO_NAME:-}" && -n "${WSL_INTEROP:-}" ]]
}

wizard_input_no_track() {
  if is_wsl_runtime; then
    printf 'n\nn\nn\n'
    return
  fi

  printf 'n\n'
}

wizard_input_track_history() {
  if is_wsl_runtime; then
    printf 'y\ny\nn\ny\n'
    return
  fi

  printf 'y\n'
}

rollback_input_permanent_delete_fallback() {
  if is_wsl_runtime; then
    printf '2\n'
    return
  fi

  printf ''
}

invoke_batch_wizard_with_input() {
  local input_payload="$1"
  shift
  local convert_to_cmd_reachable
  convert_to_cmd_reachable() {
    local raw="$1"
    if command -v wslpath >/dev/null 2>&1 && [[ "$raw" == /* ]]; then
      raw="$(wslpath -w "$raw" 2>/dev/null || printf '%s' "$raw")"
    fi
    if [[ "$raw" == \\\\wsl.localhost\\* ]]; then
      raw="\\\\wsl$\\${raw#\\\\wsl.localhost\\}"
    fi
    printf '%s' "$raw"
  }
  local repo_root_cmd
  local args_cmd=()
  repo_root_cmd="$(convert_to_cmd_reachable "$REPO_ROOT")"
  for arg in "$@"; do
    args_cmd+=("$(convert_to_cmd_reachable "$arg")")
  done

  local helper_ps1_cmd
  helper_ps1_cmd="$(convert_to_cmd_reachable "$REPO_ROOT/tools/vsc-launcher.ps1")"
  local command_line
  command_line="echo ${input_payload%%$'\r\n'}| powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper_ps1_cmd"
  for arg in "${args_cmd[@]}"; do
    command_line+=" $arg"
  done

  local output
  output="$(cmd.exe /d /s /c "$command_line" 2>&1)"
  local exit_code=$?
  printf '%s' "$output"
  return "$exit_code"
}

invoke_batch_wizard_script_with_input() {
  local input_payload="$1"
  shift
  local convert_to_cmd_reachable
  convert_to_cmd_reachable() {
    local raw="$1"
    if command -v wslpath >/dev/null 2>&1 && [[ "$raw" == /* ]]; then
      raw="$(wslpath -w "$raw" 2>/dev/null || printf '%s' "$raw")"
    fi
    if [[ "$raw" == \\\\wsl.localhost\\* ]]; then
      raw="\\\\wsl$\\${raw#\\\\wsl.localhost\\}"
    fi
    printf '%s' "$raw"
  }

  local args_cmd=()
  for arg in "$@"; do
    args_cmd+=("$(convert_to_cmd_reachable "$arg")")
  done

  local wizard_ps1_cmd
  wizard_ps1_cmd="$(convert_to_cmd_reachable "$WIZARD_SCRIPT_PS1")"
  local command_line
  command_line="echo ${input_payload%%$'\r\n'}| powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wizard_ps1_cmd"
  for arg in "${args_cmd[@]}"; do
    command_line+=" $arg"
  done

  local output
  output="$(cmd.exe /d /s /c "$command_line" 2>&1)"
  local exit_code=$?
  printf '%s' "$output"
  return "$exit_code"
}

echo "[test] Bash syntax check"
bash -n "$WIZARD_HELPER"
chmod +x "$WIZARD_HELPER"

echo "[test] PowerShell helper exists"
assert_file_exists "$WIZARD_PS1" "PowerShell helper script is missing."
assert_file_exists "$CANONICAL_LAUNCHER" "Canonical launcher script is missing."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[test] Wrapper reports missing PowerShell cleanly when unavailable"
set +e
wrapper_output="$("$WIZARD_HELPER" --help 2>&1)"
wrapper_exit=$?
set -e

if [[ "$wrapper_exit" -eq 127 ]]; then
  assert_contains "$wrapper_output" "PowerShell is required to run the wizard helper." "Wrapper error message mismatch."
  echo "[test] Skip generated-launcher integration: native PowerShell runtime not installed."
  echo "[test] Linux tests passed (limited coverage in this environment)."
  exit 0
fi
assert_exit_code "$wrapper_exit" 0 "Wrapper should return usage successfully when a working PowerShell runtime is available."

project_dir="$tmp_dir/project"
mkdir -p "$project_dir"
workspace="$project_dir/sample.code-workspace"
printf '{}' > "$workspace"
printf '# existing ignore rules\n' > "$project_dir/.gitignore"

echo "[test] Wizard helper usage output"
assert_contains "$wrapper_output" "Usage:" "Wizard helper usage output mismatch."

echo "[test] Generate project launcher"
wizard_input_no_track | "$WIZARD_HELPER" "$project_dir" >/tmp/csi-linux-wizard.out 2>&1
wizard_output="$(cat /tmp/csi-linux-wizard.out)"
assert_contains "$wizard_output" "Launcher generated successfully." "Wizard did not report successful generation."
rm -f /tmp/csi-linux-wizard.out

generated_launcher="$project_dir/vsc_launcher.sh"
generated_config="$project_dir/.vsc_launcher/config.env"
generated_manifest="$project_dir/.vsc_launcher/rollback.manifest.json"
generated_settings="$project_dir/.vscode/settings.json"
generated_gitignore="$project_dir/.gitignore"

assert_file_exists "$generated_launcher" "Generated Unix launcher was not created."
assert_file_exists "$generated_config" "Generated launcher config was not created."
assert_file_exists "$generated_manifest" "Rollback manifest was not created."
assert_file_exists "$generated_settings" "Generated VS Code settings were not created."
assert_file_exists "$generated_gitignore" "Generated gitignore was not preserved."

manifest_text="$(cat "$generated_manifest")"
assert_contains "$manifest_text" '"schemaVersion": 1' "Rollback manifest schemaVersion mismatch."
assert_contains "$manifest_text" '"launchMode": "workspace"' "Rollback manifest should record workspace launch mode."
assert_contains "$manifest_text" '"trackSessionHistory": false' "Rollback manifest should record disabled session-history tracking by default."
assert_contains "$manifest_text" '"projectRelativePath": "vsc_launcher.sh"' "Rollback manifest should record the generated launcher path."
assert_contains "$manifest_text" '"projectRelativePath": ".vscode/settings.json"' "Rollback manifest should record VS Code settings ownership."

gitignore_text="$(cat "$generated_gitignore")"
assert_contains "$gitignore_text" ".codex/*" "Generated gitignore should ignore unmanaged .codex entries by wildcard."
assert_contains "$gitignore_text" "!.codex/config.toml" "Generated gitignore should keep config.toml trackable."
if [[ "$gitignore_text" == *"!.codex/sessions/"* ]]; then
  echo "Assertion failed: session history should remain ignored by default."
  exit 1
fi

echo "[test] Generate launcher with session history tracking enabled"
if is_wsl_runtime; then
  echo "[test] Skip tracked-history integration on WSL: Windows PowerShell Read-Host over pipes is not reliable for non-default answers."
else
  project_dir_track="$tmp_dir/project-track"
  mkdir -p "$project_dir_track"
  workspace_track="$project_dir_track/sample.code-workspace"
  printf '{}' > "$workspace_track"
  printf '# existing ignore rules\n' > "$project_dir_track/.gitignore"

  wizard_input_track_history | "$WIZARD_HELPER" "$project_dir_track" >/tmp/csi-linux-wizard-track.out 2>&1
  wizard_track_output="$(cat /tmp/csi-linux-wizard-track.out)"
  assert_contains "$wizard_track_output" "Launcher generated successfully." "Wizard did not report successful tracked-history generation."
  rm -f /tmp/csi-linux-wizard-track.out

  manifest_track_text="$(cat "$project_dir_track/.vsc_launcher/rollback.manifest.json")"
  assert_contains "$manifest_track_text" '"trackSessionHistory": true' "Tracked-history rollback manifest should record enabled session-history tracking."
  gitignore_track_text="$(cat "$project_dir_track/.gitignore")"
  assert_contains "$gitignore_track_text" "!.codex/sessions/" "Tracked-history gitignore should keep sessions trackable."
  assert_contains "$gitignore_track_text" "!.codex/archived_sessions/" "Tracked-history gitignore should keep archived sessions trackable."
  assert_contains "$gitignore_track_text" "!.codex/memories/" "Tracked-history gitignore should keep memories trackable."
  assert_contains "$gitignore_track_text" "!.codex/session_index.jsonl" "Tracked-history gitignore should keep session index trackable."
fi

echo "[test] Generated launcher syntax check"
bash -n "$generated_launcher"
echo "[test] Canonical launcher syntax check"
bash -n "$CANONICAL_LAUNCHER"
chmod +x "$CANONICAL_LAUNCHER"

echo "[test] Generated launcher runs with mock code binary"
mock_bin_dir="$tmp_dir/mock-bin"
mock_output="$tmp_dir/mock-code-output.txt"
mkdir -p "$mock_bin_dir"
cat > "$mock_bin_dir/code" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'ARGS=%s\n' "$*"
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
} > "$CSI_MOCK_CODE_OUTPUT"
EOF
chmod +x "$mock_bin_dir/code"

PATH="$mock_bin_dir:$PATH" CSI_MOCK_CODE_OUTPUT="$mock_output" "$generated_launcher"
sleep 2

assert_file_exists "$mock_output" "Mock code output file was not created by the generated launcher."
mock_text="$(cat "$mock_output")"
assert_contains "$mock_text" "ARGS=--new-window $workspace" "Generated launcher did not forward the expected VS Code target."
assert_contains "$mock_text" "CODEX_HOME=$project_dir/.codex" "Generated launcher did not set project-local CODEX_HOME."

echo "[test] Canonical launcher dry-run"
canonical_dry_run="$("$CANONICAL_LAUNCHER" "$project_dir" --dry-run)"
assert_contains "$canonical_dry_run" "[dry-run] Local launch target: $workspace" "Canonical launcher should prefer the workspace target."
assert_contains "$canonical_dry_run" "[dry-run] Local CODEX_HOME: $project_dir/.codex" "Canonical launcher dry-run CODEX_HOME mismatch."

echo "[test] Canonical launcher runs with mock code binary"
rm -f "$mock_output"
PATH="$mock_bin_dir:$PATH" CSI_MOCK_CODE_OUTPUT="$mock_output" "$CANONICAL_LAUNCHER" "$project_dir"
sleep 2

assert_file_exists "$mock_output" "Mock code output file was not created by the canonical launcher."
canonical_mock_text="$(cat "$mock_output")"
assert_contains "$canonical_mock_text" "ARGS=--new-window $workspace" "Canonical launcher did not forward the expected VS Code target."
assert_contains "$canonical_mock_text" "CODEX_HOME=$project_dir/.codex" "Canonical launcher did not set project-local CODEX_HOME."

echo "[test] Rollback flow preserves user edits while removing launcher artifacts"
rollback_project="$tmp_dir/project-rollback"
mkdir -p "$rollback_project"
printf '{}' > "$rollback_project/sample.code-workspace"
printf '# rollback keep\n' > "$rollback_project/.gitignore"

wizard_input_no_track | "$WIZARD_HELPER" "$rollback_project" >/tmp/csi-linux-rollback-setup.out 2>&1
rollback_setup_output="$(cat /tmp/csi-linux-rollback-setup.out)"
assert_contains "$rollback_setup_output" "Launcher generated successfully." "Rollback setup precondition did not complete successfully."
rm -f /tmp/csi-linux-rollback-setup.out

if is_wsl_runtime; then
  echo "[test] Rollback stop mode on WSL should fail before editing managed files"
  rollback_stop_project="$tmp_dir/project-rollback-stop"
  mkdir -p "$rollback_stop_project"
  printf '{}' > "$rollback_stop_project/sample.code-workspace"
  printf '# rollback stop keep\n' > "$rollback_stop_project/.gitignore"

  wizard_input_no_track | "$WIZARD_HELPER" "$rollback_stop_project" >/tmp/csi-linux-rollback-stop-setup.out 2>&1
  rollback_stop_setup_output="$(cat /tmp/csi-linux-rollback-stop-setup.out)"
  assert_contains "$rollback_stop_setup_output" "Launcher generated successfully." "Rollback stop-mode setup precondition did not complete successfully."
  rm -f /tmp/csi-linux-rollback-stop-setup.out

  rollback_stop_gitignore_before="$(cat "$rollback_stop_project/.gitignore")"

  set +e
  rollback_stop_output="$(invoke_batch_wizard_script_with_input '' -TargetPath "$rollback_stop_project" -Rollback -RollbackDeleteBehavior Stop)"
  rollback_stop_exit=$?
  set -e

  assert_exit_code "$rollback_stop_exit" 1 "Rollback stop mode on WSL should fail before applying permanent deletion."
  assert_contains "$rollback_stop_output" "Native Trash/Recycle Bin is not available" "Rollback stop mode should report unavailable native trash."

  rollback_stop_gitignore_after="$(cat "$rollback_stop_project/.gitignore")"
  if [[ "$rollback_stop_gitignore_after" != "$rollback_stop_gitignore_before" ]]; then
    echo "Assertion failed: rollback stop mode should not edit .gitignore before failure."
    exit 1
  fi

  assert_file_exists "$rollback_stop_project/vsc_launcher.sh" "Rollback stop mode should not remove launcher before the user approves permanent deletion."
  assert_file_exists "$rollback_stop_project/.vsc_launcher" "Rollback stop mode should not remove metadata before the user approves permanent deletion."
fi

echo "[test] Rollback should preserve original line endings and formatting for unchanged tracked files"
rollback_format_project="$tmp_dir/project-rollback-format"
mkdir -p "$rollback_format_project"
cat > "$rollback_format_project/sample.code-workspace" <<'EOF'
{
  "folders": [
    {
      "path": "."
    }
  ],
  "settings": {
    "chatgpt.openOnStartup": true,
    "chatgpt.runCodexInWindowsSubsystemForLinux": false,
    "editor.formatOnSave": true
  }
}
EOF
cat > "$rollback_format_project/.gitignore" <<'EOF'
node_modules/
dist/
EOF
cp "$rollback_format_project/sample.code-workspace" "$tmp_dir/sample.code-workspace.before"
cp "$rollback_format_project/.gitignore" "$tmp_dir/gitignore.before"

wizard_input_no_track | "$WIZARD_HELPER" "$rollback_format_project" >/tmp/csi-linux-rollback-format-setup.out 2>&1
rollback_format_setup_output="$(cat /tmp/csi-linux-rollback-format-setup.out)"
assert_contains "$rollback_format_setup_output" "Launcher generated successfully." "Rollback formatting setup precondition did not complete successfully."
rm -f /tmp/csi-linux-rollback-format-setup.out

if is_wsl_runtime; then
  set +e
  rollback_format_output="$(invoke_batch_wizard_with_input $'2\r\n' --rollback "$rollback_format_project")"
  rollback_format_exit=$?
  set -e
  printf '%s' "$rollback_format_output" >/tmp/csi-linux-rollback-format.out
  assert_exit_code "$rollback_format_exit" 0 "Rollback formatting case on WSL should succeed."
else
  "$WIZARD_HELPER" --rollback "$rollback_format_project" >/tmp/csi-linux-rollback-format.out 2>&1
fi
rollback_format_output="$(cat /tmp/csi-linux-rollback-format.out)"
assert_contains "$rollback_format_output" "Rollback completed successfully." "Rollback formatting case did not report successful completion."
rm -f /tmp/csi-linux-rollback-format.out

cmp -s "$tmp_dir/sample.code-workspace.before" "$rollback_format_project/sample.code-workspace" || {
  echo "Assertion failed: rollback should restore workspace file formatting and line endings exactly when no user edits were made."
  exit 1
}
cmp -s "$tmp_dir/gitignore.before" "$rollback_format_project/.gitignore" || {
  echo "Assertion failed: rollback should restore .gitignore formatting and line endings exactly when no user edits were made."
  exit 1
}

echo "[test] Optional rollback cleanup removes Codex runtime data but preserves config.toml"
rollback_codex_project="$tmp_dir/project-rollback-codex"
mkdir -p "$rollback_codex_project"
printf '{}' > "$rollback_codex_project/sample.code-workspace"
printf '# rollback codex keep\n' > "$rollback_codex_project/.gitignore"

wizard_input_no_track | "$WIZARD_HELPER" "$rollback_codex_project" >/tmp/csi-linux-rollback-codex-setup.out 2>&1
rollback_codex_setup_output="$(cat /tmp/csi-linux-rollback-codex-setup.out)"
assert_contains "$rollback_codex_setup_output" "Launcher generated successfully." "Rollback codex-cleanup setup precondition did not complete successfully."
rm -f /tmp/csi-linux-rollback-codex-setup.out

mkdir -p "$rollback_codex_project/.codex/sessions" "$rollback_codex_project/.codex/memories" "$rollback_codex_project/.codex/skills/local"
printf 'model = "gpt-5"\n' > "$rollback_codex_project/.codex/config.toml"
printf '{"id":"session-1"}\n' > "$rollback_codex_project/.codex/sessions/session.json"
printf 'remember this\n' > "$rollback_codex_project/.codex/memories/note.md"
printf 'skill body\n' > "$rollback_codex_project/.codex/skills/local/SKILL.md"
printf 'db-bytes\n' > "$rollback_codex_project/.codex/state_5.sqlite"

if is_wsl_runtime; then
  set +e
  rollback_codex_output="$(invoke_batch_wizard_with_input $'2\r\n' --rollback --rollback-codex-runtime-data "$rollback_codex_project")"
  rollback_codex_exit=$?
  set -e
  printf '%s' "$rollback_codex_output" >/tmp/csi-linux-rollback-codex.out
  assert_exit_code "$rollback_codex_exit" 0 "Rollback codex-cleanup case on WSL should succeed."
else
  "$WIZARD_HELPER" --rollback --rollback-codex-runtime-data "$rollback_codex_project" >/tmp/csi-linux-rollback-codex.out 2>&1
fi
rollback_codex_output="$(cat /tmp/csi-linux-rollback-codex.out)"
assert_contains "$rollback_codex_output" "Rollback completed successfully." "Rollback codex-cleanup case did not report successful completion."
rm -f /tmp/csi-linux-rollback-codex.out

assert_file_exists "$rollback_codex_project/.codex/config.toml" "Rollback codex-cleanup should preserve config.toml."
assert_file_missing "$rollback_codex_project/.codex/sessions" "Rollback codex-cleanup should remove sessions."
assert_file_missing "$rollback_codex_project/.codex/memories" "Rollback codex-cleanup should remove memories."
assert_file_missing "$rollback_codex_project/.codex/skills" "Rollback codex-cleanup should remove skills."
assert_file_missing "$rollback_codex_project/.codex/state_5.sqlite" "Rollback codex-cleanup should remove runtime state files."

python3 - <<'PY' "$rollback_project/.vscode/settings.json" "$rollback_project/sample.code-workspace"
import json, sys
settings_path, workspace_path = sys.argv[1], sys.argv[2]

with open(settings_path, "r", encoding="utf-8") as fh:
    settings = json.load(fh)
settings["custom.keep"] = True
with open(settings_path, "w", encoding="utf-8") as fh:
    json.dump(settings, fh)

with open(workspace_path, "r", encoding="utf-8") as fh:
    workspace = json.load(fh)
workspace.setdefault("settings", {})["custom.workspaceKeep"] = "yes"
with open(workspace_path, "w", encoding="utf-8") as fh:
    json.dump(workspace, fh)
PY
printf 'keep-after-setup\n' >> "$rollback_project/.gitignore"

if is_wsl_runtime; then
  set +e
  rollback_output="$(invoke_batch_wizard_with_input $'2\r\n' --rollback "$rollback_project")"
  rollback_exit=$?
  set -e
  printf '%s' "$rollback_output" >/tmp/csi-linux-rollback.out
  assert_exit_code "$rollback_exit" 0 "Rollback batch invocation on WSL should succeed."
else
  "$WIZARD_HELPER" --rollback "$rollback_project" >/tmp/csi-linux-rollback.out 2>&1
fi
rollback_output="$(cat /tmp/csi-linux-rollback.out)"
assert_contains "$rollback_output" "Rollback completed successfully." "Rollback did not report successful completion."
rm -f /tmp/csi-linux-rollback.out

assert_file_missing "$rollback_project/vsc_launcher.sh" "Rollback should remove the generated Unix launcher."
assert_file_missing "$rollback_project/.vsc_launcher" "Rollback should remove the metadata directory when it was created by setup."

rollback_settings_text="$(cat "$rollback_project/.vscode/settings.json")"
assert_contains "$rollback_settings_text" '"custom.keep"' "Rollback should preserve user-added VS Code settings."
if [[ "$rollback_settings_text" == *"chatgpt.openOnStartup"* ]]; then
  echo "Assertion failed: rollback should remove wizard-managed VS Code settings when untouched."
  exit 1
fi
if [[ "$rollback_settings_text" == *"chatgpt.runCodexInWindowsSubsystemForLinux"* ]]; then
  echo "Assertion failed: rollback should remove wizard-managed WSL setting when untouched."
  exit 1
fi

rollback_workspace_text="$(cat "$rollback_project/sample.code-workspace")"
assert_contains "$rollback_workspace_text" '"custom.workspaceKeep"' "Rollback should preserve user-added workspace settings."
if [[ "$rollback_workspace_text" == *"chatgpt.openOnStartup"* ]]; then
  echo "Assertion failed: rollback should remove wizard-managed workspace settings when untouched."
  exit 1
fi
if [[ "$rollback_workspace_text" == *"chatgpt.runCodexInWindowsSubsystemForLinux"* ]]; then
  echo "Assertion failed: rollback should remove wizard-managed workspace WSL setting when untouched."
  exit 1
fi

rollback_gitignore_text="$(cat "$rollback_project/.gitignore")"
assert_contains "$rollback_gitignore_text" "keep-after-setup" "Rollback should preserve user-added .gitignore content."
if [[ "$rollback_gitignore_text" == *"# >>> codex-session-isolator >>>"* ]]; then
  echo "Assertion failed: rollback should remove the managed .gitignore block."
  exit 1
fi

echo "[test] Rollback fails safely when manifest is missing"
missing_manifest_project="$tmp_dir/project-no-manifest"
mkdir -p "$missing_manifest_project"
set +e
missing_manifest_output="$("$WIZARD_HELPER" --rollback "$missing_manifest_project" 2>&1)"
missing_manifest_exit=$?
set -e
if [[ "$missing_manifest_exit" -eq 0 ]]; then
  echo "Assertion failed: rollback without manifest should fail."
  exit 1
fi
assert_contains "$missing_manifest_output" "No launcher-managed rollback metadata found" "Rollback missing-manifest message mismatch."

echo "[test] All Linux tests passed."
