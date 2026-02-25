param(
  [string]$TargetPath
)

$ErrorActionPreference = "Stop"

function Write-Info {
  param([string]$Message)
  Write-Host "[wizard] $Message"
}

function Read-NonEmpty {
  param(
    [string]$Prompt,
    [string]$DefaultValue = ""
  )

  while ($true) {
    if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
      $value = Read-Host $Prompt
    } else {
      $value = Read-Host "$Prompt [$DefaultValue]"
      if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $DefaultValue
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
  }
}

function Read-YesNo {
  param(
    [string]$Prompt,
    [bool]$DefaultValue
  )

  $suffix = if ($DefaultValue) { "Y/n" } else { "y/N" }
  while ($true) {
    $value = Read-Host "$Prompt [$suffix]"
    if ([string]::IsNullOrWhiteSpace($value)) {
      return $DefaultValue
    }

    switch ($value.Trim().ToLowerInvariant()) {
      "y" { return $true }
      "yes" { return $true }
      "n" { return $false }
      "no" { return $false }
      default { }
    }
  }
}

function Read-ChoiceIndex {
  param(
    [string]$Title,
    [string[]]$Options,
    [int]$DefaultIndex = 0
  )

  Write-Host $Title
  for ($i = 0; $i -lt $Options.Count; $i++) {
    Write-Host ("{0}. {1}" -f ($i + 1), $Options[$i])
  }

  while ($true) {
    $raw = Read-Host ("Select [default: {0}]" -f ($DefaultIndex + 1))
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $DefaultIndex
    }

    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) {
      if ($parsed -ge 1 -and $parsed -le $Options.Count) {
        return ($parsed - 1)
      }
    }
  }
}

function Get-WslDistroList {
  try {
    $items = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) {
      return @()
    }

    return @(
      $items |
      ForEach-Object { ($_ -replace '\0', '').Trim() } |
      Where-Object { $_ -and $_ -notmatch '^docker-desktop(-data)?$' }
    )
  } catch {
    return @()
  }
}

function Ensure-JsonObjectFile {
  param(
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    try {
      $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $existing) {
        return $existing
      }
    } catch {
      $backup = "$Path.bak"
      Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
  }

  return [ordered]@{}
}

function Set-VscodeCodexWslSetting {
  param(
    [string]$RootPath,
    [bool]$Value
  )

  $vscodeDir = Join-Path $RootPath ".vscode"
  $settingsPath = Join-Path $vscodeDir "settings.json"
  New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

  $obj = Ensure-JsonObjectFile -Path $settingsPath
  $obj["chatgpt.runCodexInWindowsSubsystemForLinux"] = $Value

  $json = $obj | ConvertTo-Json -Depth 50
  Set-Content -LiteralPath $settingsPath -Value $json
}

function Update-GitIgnoreBlock {
  param(
    [string]$RootPath,
    [bool]$IgnoreSessions
  )

  $gitignorePath = Join-Path $RootPath ".gitignore"
  $startMarker = "# >>> codex-session-isolator >>>"
  $endMarker = "# <<< codex-session-isolator <<<"

  $blockLines = @(
    $startMarker
    "# Managed by Codex Session Isolator launcher wizard."
  )

  if ($IgnoreSessions) {
    $blockLines += @(
      ".codex/"
      ".vsc_launcher_logs/"
    )
  } else {
    $blockLines += @(
      ".codex/*"
      "!.codex/sessions/"
      "!.codex/sessions/**"
      "!.codex/archived_sessions/"
      "!.codex/archived_sessions/**"
      ".vsc_launcher_logs/"
    )
  }

  $blockLines += $endMarker
  $newBlock = ($blockLines -join "`n") + "`n"

  $current = ""
  if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    $current = Get-Content -LiteralPath $gitignorePath -Raw
  }

  if ([string]::IsNullOrEmpty($current)) {
    Set-Content -LiteralPath $gitignorePath -Value $newBlock
    return
  }

  $pattern = "(?ms)^" + [regex]::Escape($startMarker) + ".*?^" + [regex]::Escape($endMarker) + "\s*"
  if ($current -match $pattern) {
    $updated = [regex]::Replace($current, $pattern, $newBlock)
    Set-Content -LiteralPath $gitignorePath -Value $updated
  } else {
    if (-not $current.EndsWith("`n")) {
      $current += "`n"
    }
    $updated = $current + "`n" + $newBlock
    Set-Content -LiteralPath $gitignorePath -Value $updated
  }
}

function New-WindowsLauncherFiles {
  param(
    [string]$RootPath,
    [string]$LauncherName,
    [string]$LaunchMode,
    [string]$WorkspaceRelativePath,
    [bool]$UseRemoteWsl,
    [string]$WslDistro,
    [bool]$EnableLoggingByDefault
  )

  $configFileName = "$LauncherName.config.json"
  $ps1FileName = "$LauncherName.ps1"
  $batFileName = "$LauncherName.bat"

  $configPath = Join-Path $RootPath $configFileName
  $ps1Path = Join-Path $RootPath $ps1FileName
  $batPath = Join-Path $RootPath $batFileName

  $config = [ordered]@{
    version = 1
    launchMode = $LaunchMode
    workspaceRelativePath = $WorkspaceRelativePath
    useRemoteWsl = $UseRemoteWsl
    wslDistro = $WslDistro
    enableLoggingByDefault = $EnableLoggingByDefault
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  }

  Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 20)

  $ps1Template = @'
param(
  [switch]$Log,
  [switch]$NoLog
)

$ErrorActionPreference = "Stop"

function Fail {
  param(
    [string]$Message,
    [int]$Code = 1
  )
  Write-Host $Message
  exit $Code
}

function Convert-WindowsPathToLinuxPath {
  param(
    [string]$InputPath,
    [string]$Distro
  )

  if ($InputPath -match '^[\\]{2}(?:wsl\.localhost|wsl\$)[\\]([^\\]+)[\\](.*)$') {
    $distroInPath = $Matches[1]
    if ($distroInPath -ieq $Distro) {
      $rest = $Matches[2] -replace '\\', '/'
      return "/$rest"
    }
  }

  if ($InputPath -match '^/') {
    return $InputPath
  }

  $converted = & wsl.exe -d $Distro -- wslpath -a -u $InputPath
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
    throw "Failed to convert path '$InputPath' to Linux path in distro '$Distro'."
  }
  return $converted.Trim()
}

$configPath = Join-Path $PSScriptRoot "__CONFIG_FILE__"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
  Fail "Launcher config not found: $configPath" 2
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$enableLog = [bool]$config.enableLoggingByDefault
if ($Log) { $enableLog = $true }
if ($NoLog) { $enableLog = $false }

$logFilePath = $null
if ($enableLog) {
  $logsDir = Join-Path $PSScriptRoot ".vsc_launcher_logs"
  New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
  $launcherBase = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
  $logFilePath = Join-Path $logsDir ("{0}-{1}.log" -f $launcherBase, (Get-Date -Format "yyyyMMdd"))
}

function Write-LauncherLog {
  param([string]$Message)
  if (-not $enableLog) { return }
  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -LiteralPath $logFilePath -Value $line
}

$targetRoot = $PSScriptRoot
$launchTarget = if ($config.launchMode -eq "workspace") {
  Join-Path $targetRoot $config.workspaceRelativePath
} else {
  $targetRoot
}

if (-not (Test-Path -LiteralPath $launchTarget -PathType Any)) {
  Fail "Launch target not found: $launchTarget" 3
}

$targetItem = Get-Item -LiteralPath $launchTarget -Force
$codexHome = if ($targetItem.PSIsContainer) {
  Join-Path $launchTarget ".codex"
} else {
  Join-Path (Split-Path -Parent $launchTarget) ".codex"
}

New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
Write-LauncherLog ("LaunchTarget={0}" -f $launchTarget)
Write-LauncherLog ("CODEX_HOME={0}" -f $codexHome)

if ($config.useRemoteWsl) {
  if ([string]::IsNullOrWhiteSpace($config.wslDistro)) {
    Fail "WSL distro is not configured in launcher config." 4
  }

  $linuxTarget = Convert-WindowsPathToLinuxPath -InputPath $launchTarget -Distro $config.wslDistro
  $linuxEscaped = $linuxTarget -replace "'", "'\"'\"'"
  $bashScript = "target='$linuxEscaped'; if [ -d ""`$target"" ]; then base=""`$target""; else base=""`$(dirname ""`$target"")""; fi; codex_home=""`$base/.codex""; mkdir -p ""`$codex_home""; export CODEX_HOME=""`$codex_home""; code --new-window ""`$target"""

  Write-LauncherLog ("WSL Distro={0}" -f $config.wslDistro)
  Write-LauncherLog ("WSL Target={0}" -f $linuxTarget)
  & wsl.exe -d $config.wslDistro -- bash -lc $bashScript
  if ($LASTEXITCODE -ne 0) {
    Fail "Failed to launch VS Code in WSL mode." 5
  }
} else {
  $previousCodexHome = $env:CODEX_HOME
  $hadCodexHome = Test-Path Env:CODEX_HOME
  $hadElectronRunAsNode = Test-Path Env:ELECTRON_RUN_AS_NODE
  $previousElectronRunAsNode = $env:ELECTRON_RUN_AS_NODE

  $env:CODEX_HOME = $codexHome
  if ($hadElectronRunAsNode) {
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  }

  try {
    if (Get-Command code -ErrorAction SilentlyContinue) {
      & code --new-window $launchTarget
    } else {
      $codeExe = Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"
      if (-not (Test-Path -LiteralPath $codeExe -PathType Leaf)) {
        Fail "VS Code executable not found. Install VS Code or add 'code' to PATH." 127
      }
      & $codeExe --new-window $launchTarget
    }

    if ($LASTEXITCODE -ne 0) {
      Fail "Failed to launch VS Code." 6
    }
  } finally {
    if ($hadCodexHome) {
      $env:CODEX_HOME = $previousCodexHome
    } else {
      Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }

    if ($hadElectronRunAsNode) {
      $env:ELECTRON_RUN_AS_NODE = $previousElectronRunAsNode
    } else {
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
  }
}
'@

  $ps1Content = $ps1Template.Replace("__CONFIG_FILE__", $configFileName)
  Set-Content -LiteralPath $ps1Path -Value $ps1Content

  $batTemplate = @'
@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%__PS1_FILE__" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
'@

  $batContent = $batTemplate.Replace("__PS1_FILE__", $ps1FileName)
  Set-Content -LiteralPath $batPath -Value $batContent

  return @{
    ConfigPath = $configPath
    LauncherPowerShellPath = $ps1Path
    LauncherBatchPath = $batPath
  }
}

function New-UnixLauncherFile {
  param(
    [string]$RootPath,
    [string]$LauncherName,
    [string]$LaunchMode,
    [string]$WorkspaceRelativePath,
    [bool]$EnableLoggingByDefault
  )

  $scriptPath = Join-Path $RootPath "$LauncherName.sh"
  $enableLoggingLiteral = if ($EnableLoggingByDefault) { "1" } else { "0" }

  $template = @'
#!/usr/bin/env bash
set -euo pipefail

log_flag=""
for arg in "$@"; do
  if [[ "$arg" == "--log" ]]; then
    log_flag="on"
  elif [[ "$arg" == "--no-log" ]]; then
    log_flag="off"
  fi
done

enable_log=__ENABLE_LOG_DEFAULT__
if [[ "$log_flag" == "on" ]]; then enable_log="1"; fi
if [[ "$log_flag" == "off" ]]; then enable_log="0"; fi

write_log() {
  if [[ "$enable_log" != "1" ]]; then return; fi
  local logs_dir="$SCRIPT_DIR/.vsc_launcher_logs"
  mkdir -p "$logs_dir"
  local log_file="$logs_dir/__LAUNCHER_NAME__-$(date +%Y%m%d).log"
  printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log_file"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_MODE="__LAUNCH_MODE__"
WORKSPACE_REL="__WORKSPACE_REL__"

if [[ "$LAUNCH_MODE" == "workspace" ]]; then
  launch_target="$SCRIPT_DIR/$WORKSPACE_REL"
else
  launch_target="$SCRIPT_DIR"
fi

if [[ ! -e "$launch_target" ]]; then
  echo "Launch target not found: $launch_target"
  exit 3
fi

if [[ -d "$launch_target" ]]; then
  codex_home="$launch_target/.codex"
else
  codex_home="$(dirname "$launch_target")/.codex"
fi

mkdir -p "$codex_home"
export CODEX_HOME="$codex_home"

write_log "LaunchTarget=$launch_target"
write_log "CODEX_HOME=$codex_home"

if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in PATH."
  exit 127
fi

code --new-window "$launch_target"
'@

  $content = $template.
    Replace("__ENABLE_LOG_DEFAULT__", $enableLoggingLiteral).
    Replace("__LAUNCHER_NAME__", $LauncherName).
    Replace("__LAUNCH_MODE__", $LaunchMode).
    Replace("__WORKSPACE_REL__", $WorkspaceRelativePath)

  Set-Content -LiteralPath $scriptPath -Value $content
  try {
    & chmod +x $scriptPath | Out-Null
  } catch {
  }

  return @{
    LauncherShellPath = $scriptPath
  }
}

$platformIsWindows = $env:OS -eq "Windows_NT"

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
  $TargetPath = Read-NonEmpty -Prompt "Enter target folder path (repo or code folder)"
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Any)) {
  throw "Path not found: $TargetPath"
}

$resolvedTarget = (Resolve-Path -LiteralPath $TargetPath).Path
$targetItem = Get-Item -LiteralPath $resolvedTarget -Force
$targetRoot = if ($targetItem.PSIsContainer) { $resolvedTarget } else { Split-Path -Parent $resolvedTarget }

Write-Info ("Target root: {0}" -f $targetRoot)

$workspaceFiles = @(
  Get-ChildItem -Path $targetRoot -Filter *.code-workspace -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
  ForEach-Object { $_.FullName }
)

$launchMode = "folder"
$workspaceRelativePath = ""

if ($workspaceFiles.Count -gt 0) {
  $options = @("Open folder root")
  foreach ($ws in $workspaceFiles) {
    $relative = [IO.Path]::GetRelativePath($targetRoot, $ws)
    $options += ("Open workspace file: {0}" -f $relative)
  }

  $choice = Read-ChoiceIndex -Title "Select launch target type:" -Options $options -DefaultIndex 0
  if ($choice -gt 0) {
    $launchMode = "workspace"
    $selectedWorkspace = $workspaceFiles[$choice - 1]
    $workspaceRelativePath = [IO.Path]::GetRelativePath($targetRoot, $selectedWorkspace)
  }
}

$useRemoteWsl = $false
$wslDistro = ""

if ($platformIsWindows) {
  $useRemoteWsl = Read-YesNo -Prompt "Launch VS Code in Remote WSL mode?" -DefaultValue $false
  if ($useRemoteWsl) {
    $distros = Get-WslDistroList
    if ($distros.Count -eq 0) {
      throw "No WSL distro found. Install WSL or choose local mode."
    } elseif ($distros.Count -eq 1) {
      $wslDistro = $distros[0]
      Write-Info ("Using WSL distro: {0}" -f $wslDistro)
    } else {
      $idx = Read-ChoiceIndex -Title "Select WSL distro:" -Options $distros -DefaultIndex 0
      $wslDistro = $distros[$idx]
    }
  }
}

$codexRunInWsl = if ($platformIsWindows) {
  Read-YesNo -Prompt "Set Codex to run in WSL for this project?" -DefaultValue $useRemoteWsl
} else {
  $false
}

$ignoreSessions = Read-YesNo -Prompt "Ignore chat sessions (.codex/sessions and archived_sessions) in gitignore?" -DefaultValue $true
$enableLoggingByDefault = Read-YesNo -Prompt "Enable launcher logging by default?" -DefaultValue $false
$launcherNameRaw = Read-NonEmpty -Prompt "Launcher file name (without extension)" -DefaultValue "vsc_launcher"
$launcherName = [IO.Path]::GetFileNameWithoutExtension($launcherNameRaw.Trim())
if ([string]::IsNullOrWhiteSpace($launcherName)) {
  $launcherName = "vsc_launcher"
}

if ($platformIsWindows) {
  Set-VscodeCodexWslSetting -RootPath $targetRoot -Value $codexRunInWsl
}
Update-GitIgnoreBlock -RootPath $targetRoot -IgnoreSessions $ignoreSessions

$outputs = if ($platformIsWindows) {
  New-WindowsLauncherFiles `
    -RootPath $targetRoot `
    -LauncherName $launcherName `
    -LaunchMode $launchMode `
    -WorkspaceRelativePath $workspaceRelativePath `
    -UseRemoteWsl $useRemoteWsl `
    -WslDistro $wslDistro `
    -EnableLoggingByDefault $enableLoggingByDefault
} else {
  New-UnixLauncherFile `
    -RootPath $targetRoot `
    -LauncherName $launcherName `
    -LaunchMode $launchMode `
    -WorkspaceRelativePath $workspaceRelativePath `
    -EnableLoggingByDefault $enableLoggingByDefault
}

Write-Host ""
Write-Host "Launcher generated successfully."
foreach ($item in $outputs.GetEnumerator()) {
  Write-Host ("- {0}: {1}" -f $item.Key, $item.Value)
}
