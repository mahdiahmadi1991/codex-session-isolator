param(
  [Parameter(Mandatory = $true, Position = 0)]
  [Alias("WorkspacePath", "Path")]
  [string]$TargetPath,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Exit-WithError {
  param(
    [string]$Message,
    [int]$Code = 1
  )
  Write-Host $Message
  exit $Code
}

function Get-DefaultWslDistro {
  try {
    $statusOutput = & wsl.exe --status 2>$null
    foreach ($line in $statusOutput) {
      if ($line -match 'Default Distribution:\s*(.+)$') {
        return $Matches[1].Trim()
      }
    }
  } catch {
  }

  try {
    $list = & wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^docker-desktop(-data)?$' }
    if ($list) {
      return $list[0]
    }
  } catch {
  }

  return $null
}

function Parse-WslUncPath {
  param([string]$Path)

  if ($Path -match '^[\\]{2}(?:wsl\.localhost|wsl\$)[\\]([^\\]+)[\\](.*)$') {
    $distro = $Matches[1]
    $rest = $Matches[2] -replace '\\', '/'
    return @{
      Distro = $distro
      LinuxPath = "/$rest"
    }
  }

  return $null
}

function Start-LocalCode {
  param([string]$InputPath)

  if (-not (Test-Path -LiteralPath $InputPath -PathType Any)) {
    Exit-WithError "Path not found: $InputPath" 2
  }

  $resolvedPath = (Resolve-Path -LiteralPath $InputPath).Path
  $item = Get-Item -LiteralPath $resolvedPath -Force

  if ($item.PSIsContainer) {
    $launchTarget = $resolvedPath
    $baseDir = $resolvedPath
  } else {
    $launchTarget = $resolvedPath
    $baseDir = Split-Path -Parent $resolvedPath
  }

  $codexHome = Join-Path $baseDir ".codex"

  New-Item -ItemType Directory -Force -Path $codexHome | Out-Null

  $originalCodexHome = $env:CODEX_HOME
  $hadCodexHome = Test-Path Env:CODEX_HOME
  $hadElectronRunAsNode = Test-Path Env:ELECTRON_RUN_AS_NODE
  $originalElectronRunAsNode = $env:ELECTRON_RUN_AS_NODE

  $env:CODEX_HOME = $codexHome
  if ($hadElectronRunAsNode) {
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  }

  try {
    if ($DryRun) {
      Write-Host "[dry-run] Local launch target: $launchTarget"
      Write-Host "[dry-run] Local CODEX_HOME: $codexHome"
      return
    }

    if (Get-Command code -ErrorAction SilentlyContinue) {
      & code --new-window $launchTarget
    } else {
      $codeExe = Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"
      if (-not (Test-Path -LiteralPath $codeExe -PathType Leaf)) {
        Exit-WithError "VS Code command not found. Install 'code' in PATH or install VS Code." 127
      }
      & $codeExe --new-window $launchTarget
    }

    if ($LASTEXITCODE -ne 0) {
      Exit-WithError "Failed to launch VS Code with local path: $launchTarget" 3
    }
  } finally {
    if ($hadCodexHome) {
      $env:CODEX_HOME = $originalCodexHome
    } else {
      Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }

    if ($hadElectronRunAsNode) {
      $env:ELECTRON_RUN_AS_NODE = $originalElectronRunAsNode
    } else {
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
  }
}

function Start-WslCode {
  param(
    [string]$LinuxTargetPath,
    [string]$Distro
  )

  $targetB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LinuxTargetPath))
  $dryRunLiteral = if ($DryRun) { "1" } else { "0" }

  $bashScript = @"
set -e
target_b64='$targetB64'
dry_run='$dryRunLiteral'
target="\$(printf '%s' "\$target_b64" | base64 -d)"

if [ -d "\$target" ]; then
  launch_target="\$target"
  base_dir="\$target"
elif [ -f "\$target" ]; then
  launch_target="\$target"
  base_dir="\$(dirname "\$target")"
else
  echo "Path not found: \$target"
  exit 2
fi

codex_home="\$base_dir/.codex"
mkdir -p "\$codex_home"
export CODEX_HOME="\$codex_home"

if [ "\$dry_run" = "1" ]; then
  echo "[dry-run] WSL launch target: \$launch_target"
  echo "[dry-run] WSL CODEX_HOME: \$codex_home"
  exit 0
fi

command -v code >/dev/null 2>&1 || { echo "VS Code command 'code' not found in WSL PATH."; exit 127; }
code --new-window "\$launch_target"
"@

  if ([string]::IsNullOrWhiteSpace($Distro)) {
    Exit-WithError "No WSL distro detected. Install WSL or pass a valid WSL path." 4
  }

  & wsl.exe -d $Distro -- bash -lc $bashScript
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError "Failed to launch VS Code in WSL distro '$Distro'." 5
  }
}

$targetInput = $TargetPath.Trim()
if ([string]::IsNullOrWhiteSpace($targetInput)) {
  Exit-WithError "TargetPath is required." 1
}

$uncWsl = Parse-WslUncPath -Path $targetInput
if ($uncWsl) {
  Start-WslCode -LinuxTargetPath $uncWsl.LinuxPath -Distro $uncWsl.Distro
  exit 0
}

if ($targetInput -match '^/') {
  $defaultDistro = Get-DefaultWslDistro
  Start-WslCode -LinuxTargetPath $targetInput -Distro $defaultDistro
  exit 0
}

Start-LocalCode -InputPath $targetInput
