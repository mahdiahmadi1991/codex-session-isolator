#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PS1="$SCRIPT_DIR/vsc-launcher.ps1"

if [[ ! -f "$HELPER_PS1" ]]; then
  echo "Helper script not found: $HELPER_PS1"
  exit 2
fi

if command -v pwsh >/dev/null 2>&1; then
  PS_CMD="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  PS_CMD="powershell"
else
  echo "PowerShell is required to run the wizard helper."
  echo "Install PowerShell (pwsh): https://learn.microsoft.com/powershell/"
  exit 127
fi

"$PS_CMD" -NoProfile -ExecutionPolicy Bypass -File "$HELPER_PS1" "$@"

