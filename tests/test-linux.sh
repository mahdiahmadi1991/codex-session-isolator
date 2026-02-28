#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WIZARD_HELPER="$REPO_ROOT/tools/vsc-launcher.sh"
WIZARD_PS1="$REPO_ROOT/tools/vsc-launcher.ps1"
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

echo "[test] Bash syntax check"
bash -n "$WIZARD_HELPER"
chmod +x "$WIZARD_HELPER"

echo "[test] PowerShell helper exists"
assert_file_exists "$WIZARD_PS1" "PowerShell helper script is missing."
assert_file_exists "$CANONICAL_LAUNCHER" "Canonical launcher script is missing."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[test] Wrapper reports missing PowerShell cleanly when unavailable"
if ! command -v pwsh >/dev/null 2>&1 && ! command -v powershell >/dev/null 2>&1; then
  set +e
  wrapper_output="$("$WIZARD_HELPER" --help 2>&1)"
  wrapper_exit=$?
  set -e
  assert_exit_code "$wrapper_exit" 127 "Wrapper should exit 127 when no PowerShell runtime is available."
  assert_contains "$wrapper_output" "PowerShell is required to run the wizard helper." "Wrapper error message mismatch."
  echo "[test] Skip generated-launcher integration: native PowerShell runtime not installed."
  echo "[test] Linux tests passed (limited coverage in this environment)."
  exit 0
fi

project_dir="$tmp_dir/project"
mkdir -p "$project_dir"
workspace="$project_dir/sample.code-workspace"
printf '{}' > "$workspace"

echo "[test] Wizard helper usage output"
helper_output="$("$WIZARD_HELPER" --help)"
assert_contains "$helper_output" "Usage:" "Wizard helper usage output mismatch."

echo "[test] Generate project launcher"
printf 'n\n' | "$WIZARD_HELPER" "$project_dir" >/tmp/csi-linux-wizard.out 2>&1
wizard_output="$(cat /tmp/csi-linux-wizard.out)"
assert_contains "$wizard_output" "Launcher generated successfully." "Wizard did not report successful generation."
rm -f /tmp/csi-linux-wizard.out

generated_launcher="$project_dir/vsc_launcher.sh"
generated_config="$project_dir/.vsc_launcher/config.env"
generated_settings="$project_dir/.vscode/settings.json"

assert_file_exists "$generated_launcher" "Generated Unix launcher was not created."
assert_file_exists "$generated_config" "Generated launcher config was not created."
assert_file_exists "$generated_settings" "Generated VS Code settings were not created."

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

echo "[test] All Linux tests passed."
