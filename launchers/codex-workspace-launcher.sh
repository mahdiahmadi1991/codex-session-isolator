#!/usr/bin/env bash
set -euo pipefail

workspace_path="${1:-}"

if [[ -z "$workspace_path" ]]; then
  echo "Usage: ./codex-workspace-launcher.sh <path-to-workspace-file>"
  exit 1
fi

if [[ ! -f "$workspace_path" ]]; then
  echo "Workspace file not found: $workspace_path"
  exit 2
fi

if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in PATH."
  exit 127
fi

workspace_dir="$(cd "$(dirname "$workspace_path")" && pwd)"
workspace_file="$workspace_dir/$(basename "$workspace_path")"
codex_home="$workspace_dir/.codex"

mkdir -p "$codex_home"

export CODEX_HOME="$codex_home"
code --new-window "$workspace_file"
