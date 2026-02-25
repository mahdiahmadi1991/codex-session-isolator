param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$WorkspacePath
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

function Escape-BashSingleQuotedString {
  param([string]$Value)
  return $Value -replace "'", "'\"'\"'"
}

function Get-LinuxParentPath {
  param([string]$LinuxPath)

  $normalized = $LinuxPath -replace '\\', '/'
  if ($normalized -eq '/') {
    return '/'
  }

  $trimmed = $normalized.TrimEnd('/')
  $lastSlash = $trimmed.LastIndexOf('/')
  if ($lastSlash -lt 0) {
    return '.'
  }
  if ($lastSlash -eq 0) {
    return '/'
  }
  return $trimmed.Substring(0, $lastSlash)
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
  param([string]$WorkspaceFile)

  if (-not (Test-Path -LiteralPath $WorkspaceFile -PathType Leaf)) {
    Exit-WithError "Workspace file not found: $WorkspaceFile" 2
  }

  $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceFile).Path
  $workspaceDir = Split-Path -Parent $resolvedWorkspace
  $codexHome = Join-Path $workspaceDir ".codex"

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
    if (Get-Command code -ErrorAction SilentlyContinue) {
      & code --new-window $resolvedWorkspace
    } else {
      $codeExe = Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"
      if (-not (Test-Path -LiteralPath $codeExe -PathType Leaf)) {
        Exit-WithError "VS Code command not found. Install 'code' in PATH or install VS Code." 127
      }
      & $codeExe --new-window $resolvedWorkspace
    }

    if ($LASTEXITCODE -ne 0) {
      Exit-WithError "Failed to launch VS Code with local workspace: $resolvedWorkspace" 3
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
    [string]$LinuxWorkspacePath,
    [string]$Distro
  )

  $linuxWorkspaceDir = Get-LinuxParentPath -LinuxPath $LinuxWorkspacePath
  $linuxCodexHome = "$linuxWorkspaceDir/.codex"

  $workspaceEscaped = Escape-BashSingleQuotedString -Value $LinuxWorkspacePath
  $codexHomeEscaped = Escape-BashSingleQuotedString -Value $linuxCodexHome

  $bashScript = @"
set -e
workspace='$workspaceEscaped'
codex_home='$codexHomeEscaped'

command -v code >/dev/null 2>&1 || { echo "VS Code command 'code' not found in WSL PATH."; exit 127; }
[ -f "\$workspace" ] || { echo "Workspace file not found: \$workspace"; exit 2; }
mkdir -p "\$codex_home"
export CODEX_HOME="\$codex_home"
code --new-window "\$workspace"
"@

  if ([string]::IsNullOrWhiteSpace($Distro)) {
    Exit-WithError "No WSL distro detected. Install WSL or pass a valid WSL path." 4
  }

  & wsl.exe -d $Distro -- bash -lc $bashScript
  if ($LASTEXITCODE -ne 0) {
    Exit-WithError "Failed to launch VS Code in WSL distro '$Distro'." 5
  }
}

$workspaceInput = $WorkspacePath.Trim()
if ([string]::IsNullOrWhiteSpace($workspaceInput)) {
  Exit-WithError "WorkspacePath is required." 1
}

$uncWsl = Parse-WslUncPath -Path $workspaceInput
if ($uncWsl) {
  Start-WslCode -LinuxWorkspacePath $uncWsl.LinuxPath -Distro $uncWsl.Distro
  exit 0
}

if ($workspaceInput -match '^/') {
  $defaultDistro = Get-DefaultWslDistro
  Start-WslCode -LinuxWorkspacePath $workspaceInput -Distro $defaultDistro
  exit 0
}

Start-LocalCode -WorkspaceFile $workspaceInput
