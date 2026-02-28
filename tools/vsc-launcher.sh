#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PS1="$SCRIPT_DIR/vsc-launcher.ps1"

if [[ ! -f "$HELPER_PS1" ]]; then
  echo "Helper script not found: $HELPER_PS1"
  exit 2
fi

is_wsl_runtime() {
  [[ -n "${WSL_DISTRO_NAME:-}" && -n "${WSL_INTEROP:-}" ]]
}

probe_powershell_runtime() {
  local command_name="$1"
  "$command_name" -NoProfile -Command "exit 0" >/dev/null 2>&1
}

convert_for_windows_powershell() {
  local value="$1"
  if [[ "$value" == /* ]] && command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$value" 2>/dev/null || printf '%s' "$value"
    return
  fi

  printf '%s' "$value"
}

PS_CMD=""
USE_WINDOWS_POWERSHELL=0

if is_wsl_runtime; then
  for candidate in pwsh.exe powershell.exe; do
    if command -v "$candidate" >/dev/null 2>&1 && probe_powershell_runtime "$candidate"; then
      PS_CMD="$candidate"
      USE_WINDOWS_POWERSHELL=1
      break
    fi
  done
fi

if [[ -z "$PS_CMD" ]]; then
  for candidate in pwsh powershell; do
    if command -v "$candidate" >/dev/null 2>&1 && probe_powershell_runtime "$candidate"; then
      PS_CMD="$candidate"
      break
    fi
  done
fi

if [[ -z "$PS_CMD" ]]; then
  echo "PowerShell is required to run the wizard helper."
  echo "Install PowerShell (pwsh): https://learn.microsoft.com/powershell/"
  exit 127
fi

helper_ps1_path="$HELPER_PS1"
if [[ "$USE_WINDOWS_POWERSHELL" -eq 1 ]]; then
  helper_ps1_path="$(convert_for_windows_powershell "$HELPER_PS1")"
fi

converted_args=()
expect_target_value=0
saw_positional_target=0
for arg in "$@"; do
  if [[ "$USE_WINDOWS_POWERSHELL" -eq 1 ]]; then
    if [[ "$expect_target_value" -eq 1 ]]; then
      converted_args+=("$(convert_for_windows_powershell "$arg")")
      expect_target_value=0
      continue
    fi

    case "$arg" in
      --target|-target)
        converted_args+=("$arg")
        expect_target_value=1
        continue
        ;;
      --help|-help|-h|/\?|--debug|-debug|-debugmode)
        converted_args+=("$arg")
        continue
        ;;
      *)
        if [[ "$saw_positional_target" -eq 0 ]]; then
          converted_args+=("$(convert_for_windows_powershell "$arg")")
          saw_positional_target=1
        else
          converted_args+=("$arg")
        fi
        continue
        ;;
    esac
  fi

  converted_args+=("$arg")
done

"$PS_CMD" -NoProfile -ExecutionPolicy Bypass -File "$helper_ps1_path" "${converted_args[@]}"
