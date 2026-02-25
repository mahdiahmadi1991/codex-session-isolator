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
  launch_target="$(cd "$target_path" && pwd)"
  base_dir="$launch_target"
else
  base_dir="$(cd "$(dirname "$target_path")" && pwd)"
  launch_target="$base_dir/$(basename "$target_path")"
fi

codex_home="$base_dir/.codex"

mkdir -p "$codex_home"

export CODEX_HOME="$codex_home"

if [[ "$dry_run" == "--dry-run" ]]; then
  echo "[dry-run] Local launch target: $launch_target"
  echo "[dry-run] Local CODEX_HOME: $codex_home"
  exit 0
fi

if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in PATH."
  exit 127
fi

code --new-window "$launch_target"
