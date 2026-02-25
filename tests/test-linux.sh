#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_ROOT/launchers/codex-session-isolator.sh"
WIZARD_HELPER="$REPO_ROOT/tools/new-vsc-launcher.sh"

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
bash -n "$LAUNCHER"
bash -n "$WIZARD_HELPER"

echo "[test] Wizard helper usage output"
if command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
  helper_output="$("$WIZARD_HELPER" --help)"
  assert_contains "$helper_output" "Usage:" "Wizard helper usage output mismatch."
else
  echo "[test] Skip helper runtime test: PowerShell not installed."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

project_dir="$tmp_dir/project"
mkdir -p "$project_dir"
workspace="$project_dir/sample.code-workspace"
printf '{}' > "$workspace"

echo "[test] Folder dry-run"
folder_output="$("$LAUNCHER" "$project_dir" --dry-run)"
assert_contains "$folder_output" "[dry-run] Local launch target: $project_dir" "Folder launch target mismatch."
assert_contains "$folder_output" "[dry-run] Local CODEX_HOME: $project_dir/.codex" "Folder CODEX_HOME mismatch."

echo "[test] Workspace dry-run"
workspace_output="$("$LAUNCHER" "$workspace" --dry-run)"
assert_contains "$workspace_output" "[dry-run] Local launch target: $workspace" "Workspace launch target mismatch."
assert_contains "$workspace_output" "[dry-run] Local CODEX_HOME: $project_dir/.codex" "Workspace CODEX_HOME mismatch."

echo "[test] Invalid path"
set +e
"$LAUNCHER" "$tmp_dir/not-found.code-workspace" --dry-run >/tmp/csi-linux-invalid.out 2>&1
invalid_exit=$?
set -e
assert_exit_code "$invalid_exit" 2 "Invalid path exit code mismatch."
invalid_output="$(cat /tmp/csi-linux-invalid.out)"
assert_contains "$invalid_output" "Path not found:" "Invalid path message mismatch."
rm -f /tmp/csi-linux-invalid.out

echo "[test] Invalid second argument"
set +e
"$LAUNCHER" "$project_dir" "--unknown" >/tmp/csi-linux-arg.out 2>&1
arg_exit=$?
set -e
assert_exit_code "$arg_exit" 1 "Invalid argument exit code mismatch."
arg_output="$(cat /tmp/csi-linux-arg.out)"
assert_contains "$arg_output" "Unknown second argument:" "Invalid argument message mismatch."
rm -f /tmp/csi-linux-arg.out

echo "[test] All Linux tests passed."
