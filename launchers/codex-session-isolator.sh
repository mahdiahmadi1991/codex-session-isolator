#!/usr/bin/env bash
set -euo pipefail

target_path="${1:-}"
dry_run="${2:-}"

if [[ -z "$target_path" ]]; then
  echo "Usage: ./codex-session-isolator.sh <path-to-workspace-or-folder> [--dry-run]"
  exit 1
fi

if [[ "$dry_run" != "" && "$dry_run" != "--dry-run" ]]; then
  echo "Unknown second argument: $dry_run"
  exit 1
fi

if [[ ! -e "$target_path" ]]; then
  echo "Path not found: $target_path"
  exit 2
fi

if [[ -d "$target_path" ]]; then
  base_dir="$(cd "$target_path" && pwd)"
  launch_target="$base_dir"
  preferred_workspace="$base_dir/codex-session-isolator.code-workspace"
  if [[ -f "$preferred_workspace" ]]; then
    launch_target="$preferred_workspace"
  else
    shopt -s nullglob
    workspace_files=("$base_dir"/*.code-workspace)
    shopt -u nullglob
    if [[ "${#workspace_files[@]}" -eq 1 ]]; then
      launch_target="${workspace_files[0]}"
    fi
  fi
else
  base_dir="$(cd "$(dirname "$target_path")" && pwd)"
  launch_target="$base_dir/$(basename "$target_path")"
fi

codex_home="$base_dir/.codex"

mkdir -p "$codex_home"

export CODEX_HOME="$codex_home"

start_code_detached() {
  local target="$1"

  if command -v setsid >/dev/null 2>&1; then
    setsid -f code --new-window "$target" >/dev/null 2>&1
  elif command -v nohup >/dev/null 2>&1; then
    nohup code --new-window "$target" >/dev/null 2>&1 &
  else
    code --new-window "$target" >/dev/null 2>&1 &
  fi
}

if [[ "$dry_run" == "--dry-run" ]]; then
  echo "[dry-run] Local launch target: $launch_target"
  echo "[dry-run] Local CODEX_HOME: $codex_home"
  exit 0
fi

if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in PATH."
  exit 127
fi

start_code_detached "$launch_target"
sleep 1
