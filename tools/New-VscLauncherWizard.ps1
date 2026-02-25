param(
  [string]$TargetPath,
  [switch]$DebugMode
)

$ErrorActionPreference = "Stop"
$script:WizardLogPath = $null

function Write-Info {
  param([string]$Message)
  Write-Host "[wizard] $Message"
  if (-not [string]::IsNullOrWhiteSpace($script:WizardLogPath)) {
    $line = "{0} [wizard] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $script:WizardLogPath -Value $line
  }
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

function Normalize-WslName {
  param([string]$Name)

  $trimmed = $Name.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    return $trimmed
  }

  $tokens = $trimmed -split '\s+'
  if ($tokens.Count -gt 1) {
    $singleCharOnly = $true
    foreach ($token in $tokens) {
      if ($token.Length -gt 1) {
        $singleCharOnly = $false
        break
      }
    }

    if ($singleCharOnly) {
      return ($tokens -join "")
    }
  }

  return $trimmed
}

function Get-WslCommandText {
  param([string]$Arguments)

  $id = [Guid]::NewGuid().ToString("N")
  $outPath = Join-Path $env:TEMP ("wsl-csi-" + $id + ".out")
  $errPath = Join-Path $env:TEMP ("wsl-csi-" + $id + ".err")
  try {
    $proc = Start-Process `
      -FilePath "wsl.exe" `
      -ArgumentList $Arguments `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $outPath `
      -RedirectStandardError $errPath

    if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outPath -PathType Leaf)) {
      return ""
    }

    $bytes = [System.IO.File]::ReadAllBytes($outPath)
    if ($bytes.Length -eq 0) {
      return ""
    }

    if ($bytes.Length -ge 2 -and $bytes[1] -eq 0) {
      return [Text.Encoding]::Unicode.GetString($bytes)
    }

    return [Text.Encoding]::UTF8.GetString($bytes)
  } catch {
    return ""
  } finally {
    if (Test-Path -LiteralPath $outPath -PathType Leaf) {
      Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $errPath -PathType Leaf) {
      Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-DefaultWslDistro {
  try {
    $statusRaw = Get-WslCommandText -Arguments "--status"
    if ([string]::IsNullOrWhiteSpace($statusRaw)) {
      return $null
    }

    $statusText = ($statusRaw -replace [string][char]0, "")
    if ($statusText -match '(?im)Default\s*Distribution:\s*([^\r\n]+)') {
      return (Normalize-WslName -Name $Matches[1])
    }
  } catch {
  }

  return $null
}

function Get-WslDistroList {
  $distros = @()

  try {
    $lines = cmd /c "wsl -l -q" 2>$null
    foreach ($line in $lines) {
      $clean = Normalize-WslName -Name (($line -replace [string][char]0, "").Trim())
      if (-not [string]::IsNullOrWhiteSpace($clean) -and $clean -notmatch '^docker-desktop(-data)?$') {
        $distros += $clean
      }
    }
  } catch {
  }

  if ($distros.Count -gt 0) {
    return @($distros | Select-Object -Unique)
  }

  $defaultDistro = Get-DefaultWslDistro
  if (-not [string]::IsNullOrWhiteSpace($defaultDistro)) {
    return @($defaultDistro)
  }

  return @()
}

function Test-WslAvailable {
  if ($env:CSI_FORCE_NO_WSL -eq "1") {
    return $false
  }

  try {
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
      return $false
    }

    $null = cmd /c "wsl --status >nul 2>nul"
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    return $true
  } catch {
    return $false
  }
}

function Get-RelativePathSafe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

  $method = [IO.Path].GetMethod("GetRelativePath", [Type[]]@([string], [string]))
  if ($null -ne $method) {
    return [IO.Path]::GetRelativePath($BasePath, $TargetPath)
  }

  $baseResolved = (Resolve-Path -LiteralPath $BasePath).Path
  $targetResolved = (Resolve-Path -LiteralPath $TargetPath).Path

  $separator = [IO.Path]::DirectorySeparatorChar
  $baseWithSlash = $baseResolved.TrimEnd('\', '/') + $separator

  $baseUri = [Uri]$baseWithSlash
  $targetUri = [Uri]$targetResolved
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  $relative = [Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', $separator)

  if ([string]::IsNullOrWhiteSpace($relative)) {
    return "."
  }

  return $relative
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

function Convert-ToHashtable {
  param(
    [Parameter(Mandatory = $true)]
    $InputObject
  )

  if ($InputObject -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
      $result[$key] = $InputObject[$key]
    }
    return $result
  }

  $result = [ordered]@{}
  foreach ($prop in $InputObject.PSObject.Properties) {
    $result[$prop.Name] = $prop.Value
  }
  return $result
}

function Set-VscodeChatGptSettings {
  param(
    [string]$RootPath,
    [bool]$RunCodexInWsl
  )

  $vscodeDir = Join-Path $RootPath ".vscode"
  $settingsPath = Join-Path $vscodeDir "settings.json"
  New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

  $obj = Ensure-JsonObjectFile -Path $settingsPath
  if ($obj -isnot [System.Collections.IDictionary]) {
    $obj = Convert-ToHashtable -InputObject $obj
  }
  $previousRunCodexInWsl = $null
  $previousOpenOnStartup = $null
  if ($obj.Contains("chatgpt.runCodexInWindowsSubsystemForLinux")) {
    $raw = $obj["chatgpt.runCodexInWindowsSubsystemForLinux"]
    if ($raw -is [bool]) {
      $previousRunCodexInWsl = $raw
    }
  }
  if ($obj.Contains("chatgpt.openOnStartup")) {
    $raw = $obj["chatgpt.openOnStartup"]
    if ($raw -is [bool]) {
      $previousOpenOnStartup = $raw
    }
  }

  $obj["chatgpt.runCodexInWindowsSubsystemForLinux"] = $RunCodexInWsl
  $obj["chatgpt.openOnStartup"] = $true

  $json = $obj | ConvertTo-Json -Depth 50
  Set-Content -LiteralPath $settingsPath -Value $json

  return @{
    PreviousRunCodexInWsl = $previousRunCodexInWsl
    PreviousOpenOnStartup = $previousOpenOnStartup
  }
}

function Set-CodeWorkspaceChatGptSettings {
  param(
    [string]$WorkspacePath,
    [bool]$RunCodexInWsl
  )

  if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Leaf)) {
    return @{
      Applied = $false
      Reason = "Workspace file not found."
    }
  }

  $raw = Get-Content -LiteralPath $WorkspacePath -Raw
  $workspaceObject = $null
  try {
    $workspaceObject = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return @{
      Applied = $false
      Reason = "Workspace file is not valid JSON and could not be updated safely."
    }
  }

  if ($workspaceObject -isnot [System.Collections.IDictionary]) {
    $workspaceObject = Convert-ToHashtable -InputObject $workspaceObject
  }

  $settings = $null
  if ($workspaceObject.Contains("settings")) {
    $settings = $workspaceObject["settings"]
  }

  if ($null -eq $settings) {
    $settings = [ordered]@{}
  } elseif ($settings -isnot [System.Collections.IDictionary]) {
    $settings = Convert-ToHashtable -InputObject $settings
  }

  $previousRunCodexInWsl = $null
  $previousOpenOnStartup = $null
  if ($settings.Contains("chatgpt.runCodexInWindowsSubsystemForLinux")) {
    $rawRun = $settings["chatgpt.runCodexInWindowsSubsystemForLinux"]
    if ($rawRun -is [bool]) {
      $previousRunCodexInWsl = $rawRun
    }
  }
  if ($settings.Contains("chatgpt.openOnStartup")) {
    $rawOpen = $settings["chatgpt.openOnStartup"]
    if ($rawOpen -is [bool]) {
      $previousOpenOnStartup = $rawOpen
    }
  }

  $settings["chatgpt.runCodexInWindowsSubsystemForLinux"] = $RunCodexInWsl
  $settings["chatgpt.openOnStartup"] = $true
  $workspaceObject["settings"] = $settings

  Set-Content -LiteralPath $WorkspacePath -Value ($workspaceObject | ConvertTo-Json -Depth 50)
  return @{
    Applied = $true
    Reason = ""
    PreviousRunCodexInWsl = $previousRunCodexInWsl
    PreviousOpenOnStartup = $previousOpenOnStartup
  }
}

function Update-GitIgnoreBlock {
  param(
    [string]$RootPath,
    [bool]$IgnoreSessions,
    [string]$LauncherFileName,
    [string]$MetadataDirName
  )

  $gitignorePath = Join-Path $RootPath ".gitignore"
  $startMarker = "# >>> codex-session-isolator >>>"
  $endMarker = "# <<< codex-session-isolator <<<"

  $blockLines = @(
    $startMarker
    "# Managed by Codex Session Isolator launcher wizard."
    $LauncherFileName
    "$MetadataDirName/"
  )

  if ($IgnoreSessions) {
    $blockLines += @(
      ".codex/"
    )
  } else {
    $blockLines += @(
      ".codex/*"
      "!.codex/sessions/"
      "!.codex/sessions/**"
      "!.codex/archived_sessions/"
      "!.codex/archived_sessions/**"
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

function Initialize-WizardLogging {
  param(
    [string]$RootPath,
    [string]$MetadataDirName
  )

  $metaDir = Join-Path $RootPath $MetadataDirName
  $logsDir = Join-Path $metaDir "logs"
  New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
  $script:WizardLogPath = Join-Path $logsDir ("wizard-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
  Set-Content -LiteralPath $script:WizardLogPath -Value ("{0} [wizard] start" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"))
}

function Get-WizardDefaults {
  param(
    [string]$RootPath,
    [string]$MetadataDirName
  )

  $metaDir = Join-Path $RootPath $MetadataDirName
  $defaultsPath = Join-Path $metaDir "wizard.defaults.json"
  $values = [ordered]@{
    useRemoteWsl = $null
    codexRunInWsl = $null
    ignoreSessions = $null
  }

  if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
    try {
      $obj = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json -ErrorAction Stop
      foreach ($key in @("useRemoteWsl", "codexRunInWsl", "ignoreSessions")) {
        if ($obj.PSObject.Properties.Name -contains $key) {
          $raw = $obj.$key
          if ($raw -is [bool]) {
            $values[$key] = $raw
          }
        }
      }
    } catch {
    }
  }

  return @{
    Path = $defaultsPath
    Values = $values
  }
}

function Save-WizardDefaults {
  param(
    [string]$DefaultsPath,
    [bool]$UseRemoteWsl,
    [bool]$CodexRunInWsl,
    [bool]$IgnoreSessions
  )

  $parent = Split-Path -Parent $DefaultsPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null

  $payload = [ordered]@{
    useRemoteWsl = $UseRemoteWsl
    codexRunInWsl = $CodexRunInWsl
    ignoreSessions = $IgnoreSessions
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  }

  Set-Content -LiteralPath $DefaultsPath -Value ($payload | ConvertTo-Json -Depth 10)
}

function Remove-LegacyGeneratedArtifacts {
  param(
    [string]$RootPath,
    [string]$LauncherBaseName
  )

  $legacyPaths = @(
    (Join-Path $RootPath "$LauncherBaseName.ps1"),
    (Join-Path $RootPath "$LauncherBaseName.config.json"),
    (Join-Path $RootPath ".vsc_launcher_logs")
  )

  foreach ($path in $legacyPaths) {
    if (Test-Path -LiteralPath $path -PathType Any) {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function New-WindowsLauncherFile {
  param(
    [string]$RootPath,
    [string]$LauncherBaseName,
    [string]$MetadataDirName,
    [string]$LaunchMode,
    [string]$WorkspaceRelativePath,
    [bool]$UseRemoteWsl,
    [string]$WslDistro,
    [bool]$CodexRunInWsl,
    [bool]$EnableLoggingByDefault
  )

  $metadataDirPath = Join-Path $RootPath $MetadataDirName
  $configPath = Join-Path $metadataDirPath "config.json"
  $runnerPath = Join-Path $metadataDirPath "runner.ps1"
  $launcherPath = Join-Path $RootPath "$LauncherBaseName.bat"

  New-Item -ItemType Directory -Force -Path $metadataDirPath | Out-Null

  $config = [ordered]@{
    version = 1
    launchMode = $LaunchMode
    workspaceRelativePath = $WorkspaceRelativePath
    useRemoteWsl = $UseRemoteWsl
    wslDistro = $WslDistro
    codexRunInWsl = $CodexRunInWsl
    forceIsolatedCodeProcess = $true
    enableLoggingByDefault = $EnableLoggingByDefault
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  }

  Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 20)

  $runnerTemplate = @'
param(
  [switch]$Log,
  [switch]$NoLog,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:ExitCode = 1
$script:EnableLog = $false
$script:LogFilePath = $null
$script:RunId = [Guid]::NewGuid().ToString("N")

function Write-LauncherLog {
  param([string]$Message)
  if (-not $script:EnableLog -or [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
    return
  }

  $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $script:RunId, $Message
  Add-Content -LiteralPath $script:LogFilePath -Value $line
}

function Fail {
  param(
    [string]$Message,
    [int]$Code = 1
  )
  $script:ExitCode = $Code
  throw $Message
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

  if ($InputPath -match '^[A-Za-z]:[\\/]') {
    $drive = $InputPath.Substring(0, 1).ToLowerInvariant()
    $rest = $InputPath.Substring(2) -replace '\\', '/'
    if (-not $rest.StartsWith('/')) {
      $rest = '/' + $rest
    }
    return "/mnt/$drive$rest"
  }

  $normalized = $InputPath -replace '\\', '/'
  $convertedRaw = & wsl.exe -d $Distro -- wslpath -a -u $normalized 2>&1
  $converted = ($convertedRaw | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
    throw "Failed to convert path '$InputPath' to Linux path in distro '$Distro'. wslpath: $converted"
  }
  return $converted
}

function Convert-ToHashtable {
  param([Parameter(Mandatory = $true)]$InputObject)

  if ($InputObject -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
      $result[$key] = $InputObject[$key]
    }
    return $result
  }

  $result = [ordered]@{}
  foreach ($prop in $InputObject.PSObject.Properties) {
    $result[$prop.Name] = $prop.Value
  }
  return $result
}

function Escape-BashSingleQuoted {
  param([string]$Value)
  $separator = "'" + '"' + "'" + '"' + "'"
  return [string]::Join($separator, ($Value -split "'"))
}

function Ensure-CodexCliWrapperSetting {
  param(
    [string]$UserDataDir,
    [bool]$EnableWrapper,
    [string]$CodexHomeWindowsPath
  )

  $userDir = Join-Path $UserDataDir "User"
  $settingsPath = Join-Path $userDir "settings.json"
  New-Item -ItemType Directory -Force -Path $userDir | Out-Null

  $settings = [ordered]@{}
  if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
      $loaded = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $loaded) {
        $settings = Convert-ToHashtable -InputObject $loaded
      }
    } catch {
      Copy-Item -LiteralPath $settingsPath -Destination ($settingsPath + ".bak") -Force -ErrorAction SilentlyContinue
      $settings = [ordered]@{}
    }
  }

  $wrapperPathWindows = Join-Path $PSScriptRoot "codex-wsl-wrapper.sh"
  $wrapperPathLinux = Convert-WindowsPathToLinuxPath -InputPath $wrapperPathWindows -Distro ""
  if (-not $EnableWrapper) {
    if ($settings.Contains("chatgpt.cliExecutable") -and [string]$settings["chatgpt.cliExecutable"] -eq $wrapperPathLinux) {
      $settings.Remove("chatgpt.cliExecutable") | Out-Null
      Write-LauncherLog "Removed chatgpt.cliExecutable wrapper override."
    }
    Set-Content -LiteralPath $settingsPath -Value ($settings | ConvertTo-Json -Depth 20)
    return
  }

  $codexHomeLinux = Convert-WindowsPathToLinuxPath -InputPath $CodexHomeWindowsPath -Distro ""
  $logsDirWindows = Join-Path $PSScriptRoot "logs"
  New-Item -ItemType Directory -Force -Path $logsDirWindows | Out-Null
  $wrapperLogLinux = Convert-WindowsPathToLinuxPath -InputPath (Join-Path $logsDirWindows "codex-wrapper.log") -Distro ""

  $wrapperLines = @(
    "#!/usr/bin/env bash"
    "set -euo pipefail"
    "log_file='" + (Escape-BashSingleQuoted -Value $wrapperLogLinux) + "'"
    "mkdir -p `"`$(dirname `"`$log_file`")`""
    "original_codex_home=`"`${CODEX_HOME-}`""
    "export CODEX_HOME='" + (Escape-BashSingleQuoted -Value $codexHomeLinux) + "'"
    "resolved_codex_bin=`"`$(command -v codex 2>/dev/null || true)`""
    "printf '%s CODEX_HOME_ORIGINAL=%s CODEX_HOME_FORCED=%s CODEX_BIN=%s ARGS=%s\n' `"`$(date '+%Y-%m-%d %H:%M:%S')`" `"`$original_codex_home`" `"`$CODEX_HOME`" `"`$resolved_codex_bin`" `"`$*`" >> `"`$log_file`""
    "printf '%s PWD=%s HOME=%s\n' `"`$(date '+%Y-%m-%d %H:%M:%S')`" `"`$PWD`" `"`$HOME`" >> `"`$log_file`""
    "exec codex `"`$@`""
  )

  $wrapperContent = ($wrapperLines -join "`n") + "`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($wrapperPathWindows, $wrapperContent, $utf8NoBom)

  try {
    $escapedWrapper = Escape-BashSingleQuoted -Value $wrapperPathLinux
    $null = & wsl.exe -- bash -lc ("chmod +x '" + $escapedWrapper + "'")
  } catch {
    Write-LauncherLog ("WARN=Failed to set executable permission for wrapper. error={0}" -f $_.Exception.Message)
  }

  $settings["chatgpt.cliExecutable"] = $wrapperPathLinux
  Set-Content -LiteralPath $settingsPath -Value ($settings | ConvertTo-Json -Depth 20)
  Write-LauncherLog ("Configured chatgpt.cliExecutable={0}" -f $wrapperPathLinux)
}

try {
  $configPath = Join-Path $PSScriptRoot "config.json"
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Fail "Launcher config not found: $configPath" 2
  }

  $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $script:EnableLog = [bool]$config.enableLoggingByDefault
  if ($env:VSC_LAUNCHER_LOG -eq "1" -or $env:VSC_LAUNCHER_LOG -ieq "true") {
    $script:EnableLog = $true
  }
  if ($Log) { $script:EnableLog = $true }
  if ($NoLog) { $script:EnableLog = $false }

  if ($script:EnableLog) {
    $logsDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $script:LogFilePath = Join-Path $logsDir ("launcher-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
  }

  $forceIsolatedCodeProcess = $true
  if ($config.PSObject.Properties.Name -contains "forceIsolatedCodeProcess") {
    $forceIsolatedCodeProcess = [bool]$config.forceIsolatedCodeProcess
  }
  $codexRunInWsl = $false
  if ($config.PSObject.Properties.Name -contains "codexRunInWsl") {
    $codexRunInWsl = [bool]$config.codexRunInWsl
  }

  Write-LauncherLog "START"
  Write-LauncherLog ("ConfigPath={0}" -f $configPath)
  Write-LauncherLog ("Config={0}" -f (($config | ConvertTo-Json -Compress -Depth 20)))
  Write-LauncherLog ("User={0} Machine={1} PID={2} PS={3}" -f $env:USERNAME, $env:COMPUTERNAME, $PID, $PSVersionTable.PSVersion)
  Write-LauncherLog ("ForceIsolatedCodeProcess={0}" -f $forceIsolatedCodeProcess)
  Write-LauncherLog ("CodexRunInWsl={0}" -f $codexRunInWsl)

  $targetRoot = Split-Path -Parent $PSScriptRoot
  $launchTarget = if ($config.launchMode -eq "workspace") {
    Join-Path $targetRoot ([string]$config.workspaceRelativePath)
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

  $shouldUseIsolatedUserData = $forceIsolatedCodeProcess -and -not [bool]$config.useRemoteWsl
  $userDataDir = $null
  if ($shouldUseIsolatedUserData) {
    $userDataDir = Join-Path $PSScriptRoot "vscode-user-data"
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    Write-LauncherLog ("VSCodeUserDataDir={0}" -f $userDataDir)
  } elseif ($forceIsolatedCodeProcess -and [bool]$config.useRemoteWsl) {
    Write-LauncherLog "RemoteWSLNote=Skipping isolated VS Code user-data-dir in Remote WSL mode."
  }

  if ($DryRun) {
    Write-Host ("[dry-run] Launch target: {0}" -f $launchTarget)
    Write-Host ("[dry-run] CODEX_HOME: {0}" -f $codexHome)
    if ($shouldUseIsolatedUserData -and -not [string]::IsNullOrWhiteSpace($userDataDir)) {
      Write-Host ("[dry-run] VSCode user-data-dir: {0}" -f $userDataDir)
    }
    $script:ExitCode = 0
    return
  }

  $enableCodexCliWrapper = $codexRunInWsl -and -not [bool]$config.useRemoteWsl
  if ($shouldUseIsolatedUserData -and -not [string]::IsNullOrWhiteSpace($userDataDir)) {
    Ensure-CodexCliWrapperSetting `
      -UserDataDir $userDataDir `
      -EnableWrapper $enableCodexCliWrapper `
      -CodexHomeWindowsPath $codexHome
  }

  if ($config.useRemoteWsl) {
    if ([string]::IsNullOrWhiteSpace($config.wslDistro)) {
      Fail "WSL distro is not configured in launcher config." 4
    }

    $linuxTarget = Convert-WindowsPathToLinuxPath -InputPath $launchTarget -Distro $config.wslDistro
    $targetB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linuxTarget))
    $bashScript = @"
set -euo pipefail
target_b64='$targetB64'
target=`$(printf '%s' "`$target_b64" | base64 -d)
if [ -z "`$target" ]; then
  echo "Resolved target is empty."
  exit 2
fi
if [ -d "`$target" ]; then
  base="`$target"
else
  base=`$(dirname "`$target")
fi
codex_home="`$base/.codex"
mkdir -p "`$codex_home"
export CODEX_HOME="`$codex_home"
if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in WSL PATH."
  exit 127
fi
code --new-window "`$target"
"@
    $bashScript = ($bashScript -replace "`r`n", "`n") -replace "`r", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tempScriptWindows = Join-Path $env:TEMP ("csi-wsl-" + $script:RunId + ".sh")
    [System.IO.File]::WriteAllText($tempScriptWindows, $bashScript, $utf8NoBom)
    $tempScriptLinux = Convert-WindowsPathToLinuxPath -InputPath $tempScriptWindows -Distro $config.wslDistro

    Write-LauncherLog ("Mode=RemoteWSL Distro={0}" -f $config.wslDistro)
    Write-LauncherLog ("WSLTarget={0}" -f $linuxTarget)
    Write-LauncherLog ("WSLScriptLinuxPath={0}" -f $tempScriptLinux)
    if ($script:EnableLog -and -not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
      $launcherLogsDir = Split-Path -Parent $script:LogFilePath
      if (-not [string]::IsNullOrWhiteSpace($launcherLogsDir)) {
        $scriptSnapshotPath = Join-Path $launcherLogsDir ("remote-wsl-script-{0}.sh" -f $script:RunId)
        [System.IO.File]::WriteAllText($scriptSnapshotPath, $bashScript, $utf8NoBom)
        Write-LauncherLog ("WSLScriptSnapshot={0}" -f $scriptSnapshotPath)
      }
    }

    $outPath = Join-Path $env:TEMP ("csi-wsl-" + $script:RunId + ".out")
    $errPath = Join-Path $env:TEMP ("csi-wsl-" + $script:RunId + ".err")
    $remoteExitCode = 0
    $remoteOutputText = ""
    try {
      $process = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList @("-d", [string]$config.wslDistro, "--", "bash", $tempScriptLinux) `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $outPath `
        -RedirectStandardError $errPath

      $remoteExitCode = $process.ExitCode
      $stdoutText = if (Test-Path -LiteralPath $outPath -PathType Leaf) { Get-Content -LiteralPath $outPath -Raw } else { "" }
      $stderrText = if (Test-Path -LiteralPath $errPath -PathType Leaf) { Get-Content -LiteralPath $errPath -Raw } else { "" }
      $remoteOutputText = ($stdoutText + "`n" + $stderrText).Trim()
    } finally {
      if (Test-Path -LiteralPath $tempScriptWindows -PathType Leaf) {
        Remove-Item -LiteralPath $tempScriptWindows -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $outPath -PathType Leaf) {
        Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $errPath -PathType Leaf) {
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($remoteOutputText)) {
      foreach ($line in ($remoteOutputText -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
          Write-LauncherLog ("WSL={0}" -f $line)
        }
      }
    }
    if ($remoteExitCode -ne 0) {
      if ([string]::IsNullOrWhiteSpace($remoteOutputText)) {
        Fail ("Failed to launch VS Code in WSL mode. ExitCode={0}" -f $remoteExitCode) 5
      }
      Fail ("Failed to launch VS Code in WSL mode. ExitCode={0}. Output={1}" -f $remoteExitCode, $remoteOutputText) 5
    }
  } else {
    $previousCodexHome = $env:CODEX_HOME
    $hadCodexHome = Test-Path Env:CODEX_HOME
    $hadElectronRunAsNode = Test-Path Env:ELECTRON_RUN_AS_NODE
    $previousElectronRunAsNode = $env:ELECTRON_RUN_AS_NODE
    $hadWslEnv = Test-Path Env:WSLENV
    $previousWslEnv = $env:WSLENV

    $env:CODEX_HOME = $codexHome
    if ($hadElectronRunAsNode) {
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
    if ($codexRunInWsl -and -not $config.useRemoteWsl) {
      $wslEntries = @()
      if ($hadWslEnv -and -not [string]::IsNullOrWhiteSpace($previousWslEnv)) {
        $wslEntries = @($previousWslEnv -split ":" | Where-Object { $_ -and ($_ -notmatch "^CODEX_HOME(?:/.*)?$") })
      }
      $wslEntries += "CODEX_HOME/p"
      $env:WSLENV = ($wslEntries -join ":")
      Write-LauncherLog ("WSLENV={0}" -f $env:WSLENV)
    }

    try {
      $codeCommand = Get-Command code -ErrorAction SilentlyContinue
      if ($null -ne $codeCommand) {
        Write-LauncherLog ("Mode=Local CodeCommand={0}" -f $codeCommand.Source)
        if ($forceIsolatedCodeProcess -and -not [string]::IsNullOrWhiteSpace($userDataDir)) {
          & code --new-window --user-data-dir $userDataDir $launchTarget
        } else {
          & code --new-window $launchTarget
        }
      } else {
        $codeExe = Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"
        if (-not (Test-Path -LiteralPath $codeExe -PathType Leaf)) {
          Fail "VS Code executable not found. Install VS Code or add 'code' to PATH." 127
        }
        Write-LauncherLog ("Mode=Local CodeCommand={0}" -f $codeExe)
        if ($forceIsolatedCodeProcess -and -not [string]::IsNullOrWhiteSpace($userDataDir)) {
          & $codeExe --new-window --user-data-dir $userDataDir $launchTarget
        } else {
          & $codeExe --new-window $launchTarget
        }
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
      if ($hadWslEnv) {
        $env:WSLENV = $previousWslEnv
      } else {
        Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
      }
    }
  }

  $script:ExitCode = 0
} catch {
  $message = $_.Exception.Message
  Write-LauncherLog ("ERROR={0}" -f $message)
  if ($_.ScriptStackTrace) {
    Write-LauncherLog ("STACK={0}" -f $_.ScriptStackTrace)
  }
  Write-Host $message
} finally {
  Write-LauncherLog ("END ExitCode={0}" -f $script:ExitCode)
}

exit $script:ExitCode
'@

  Set-Content -LiteralPath $runnerPath -Value $runnerTemplate

  $batTemplate = @'
@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "RUNNER=%SCRIPT_DIR%__META_DIR__\runner.ps1"
if not exist "%RUNNER%" (
  echo Launcher runner not found: %RUNNER%
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%RUNNER%" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
'@

  $batContent = $batTemplate.Replace("__META_DIR__", $MetadataDirName)
  Set-Content -LiteralPath $launcherPath -Value $batContent

  return @{
    ConfigPath = $configPath
    LauncherPath = $launcherPath
    RunnerPath = $runnerPath
    MetadataPath = $metadataDirPath
  }
}

function New-UnixLauncherFile {
  param(
    [string]$RootPath,
    [string]$LauncherBaseName,
    [string]$MetadataDirName,
    [string]$LaunchMode,
    [string]$WorkspaceRelativePath,
    [bool]$EnableLoggingByDefault
  )

  $scriptPath = Join-Path $RootPath "$LauncherBaseName.sh"
  $metadataDirPath = Join-Path $RootPath $MetadataDirName
  $configPath = Join-Path $metadataDirPath "config.env"
  New-Item -ItemType Directory -Force -Path $metadataDirPath | Out-Null

  $workspaceRelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($WorkspaceRelativePath))
  $enableLoggingLiteral = if ($EnableLoggingByDefault) { "1" } else { "0" }
  $configContent = @"
LAUNCH_MODE='$LaunchMode'
WORKSPACE_REL_B64='$workspaceRelB64'
ENABLE_LOGGING='$enableLoggingLiteral'
"@
  Set-Content -LiteralPath $configPath -Value $configContent

  $template = @'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$SCRIPT_DIR/__META_DIR__"
CONFIG_FILE="$META_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Launcher config not found: $CONFIG_FILE"
  exit 2
fi
source "$CONFIG_FILE"
WORKSPACE_REL="$(printf '%s' "${WORKSPACE_REL_B64:-}" | base64 -d 2>/dev/null || true)"

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

if [[ "${ENABLE_LOGGING:-0}" == "1" ]]; then
  logs_dir="$META_DIR/logs"
  mkdir -p "$logs_dir"
  log_file="$logs_dir/launcher-$(date +%Y%m%d).log"
  printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "LaunchTarget=$launch_target" >> "$log_file"
  printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "CODEX_HOME=$codex_home" >> "$log_file"
fi

if ! command -v code >/dev/null 2>&1; then
  echo "VS Code command 'code' not found in PATH."
  exit 127
fi

code --new-window "$launch_target"
'@

  $content = $template.Replace("__META_DIR__", $MetadataDirName)

  Set-Content -LiteralPath $scriptPath -Value $content
  try {
    & chmod +x $scriptPath | Out-Null
  } catch {
  }

  return @{
    LauncherPath = $scriptPath
    ConfigPath = $configPath
    MetadataPath = $metadataDirPath
  }
}

$platformIsWindows = $env:OS -eq "Windows_NT"
$launcherBaseName = "vsc_launcher"
$metadataDirName = ".vsc_launcher"
$launcherFileName = if ($platformIsWindows) { "$launcherBaseName.bat" } else { "$launcherBaseName.sh" }
$enableLoggingByDefault = [bool]$DebugMode

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
  $TargetPath = Read-NonEmpty -Prompt "Enter target folder path (repo or code folder)"
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Any)) {
  throw "Path not found: $TargetPath"
}

$resolvedTarget = (Resolve-Path -LiteralPath $TargetPath).Path
$targetItem = Get-Item -LiteralPath $resolvedTarget -Force
$targetRoot = if ($targetItem.PSIsContainer) { $resolvedTarget } else { Split-Path -Parent $resolvedTarget }
Initialize-WizardLogging -RootPath $targetRoot -MetadataDirName $metadataDirName
$defaultsInfo = Get-WizardDefaults -RootPath $targetRoot -MetadataDirName $metadataDirName
$wizardDefaults = $defaultsInfo.Values

Write-Info ("Target root: {0}" -f $targetRoot)
Write-Info ("Generated launcher file: {0}" -f $launcherFileName)
Write-Info ("Wizard log: {0}" -f $script:WizardLogPath)
if ($null -ne $wizardDefaults.useRemoteWsl -or $null -ne $wizardDefaults.codexRunInWsl -or $null -ne $wizardDefaults.ignoreSessions) {
  Write-Info ("Loaded defaults: remoteWsl={0}, codexInWsl={1}, ignoreSessions={2}" -f $wizardDefaults.useRemoteWsl, $wizardDefaults.codexRunInWsl, $wizardDefaults.ignoreSessions)
}

$launchMode = "folder"
$workspaceRelativePath = ""

if (-not $targetItem.PSIsContainer -and $targetItem.Extension -ieq ".code-workspace") {
  $launchMode = "workspace"
  $workspaceRelativePath = Get-RelativePathSafe -BasePath $targetRoot -TargetPath $resolvedTarget
  Write-Info ("Launch target defaulted to workspace: {0}" -f $workspaceRelativePath)
} else {
  $workspaceFiles = @(
    Get-ChildItem -Path $targetRoot -Filter *.code-workspace -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName }
  )

  if ($workspaceFiles.Count -eq 0) {
    Write-Info "No workspace file found. Launch target defaulted to folder root."
  } elseif ($workspaceFiles.Count -eq 1) {
    $launchMode = "workspace"
    $workspaceRelativePath = Get-RelativePathSafe -BasePath $targetRoot -TargetPath $workspaceFiles[0]
    Write-Info ("Single workspace found. Launch target defaulted to: {0}" -f $workspaceRelativePath)
  } else {
    $options = @()
    foreach ($ws in $workspaceFiles) {
      $relative = Get-RelativePathSafe -BasePath $targetRoot -TargetPath $ws
      $options += $relative
    }

    $choice = Read-ChoiceIndex -Title "Multiple workspace files found. Select one:" -Options $options -DefaultIndex 0
    $launchMode = "workspace"
    $workspaceRelativePath = $options[$choice]
    Write-Info ("Selected workspace: {0}" -f $workspaceRelativePath)
  }
}

$useRemoteWsl = $false
$wslDistro = ""
$wslAvailable = $platformIsWindows -and (Test-WslAvailable)

if ($platformIsWindows -and $wslAvailable) {
  $remoteDefault = if ($null -ne $wizardDefaults.useRemoteWsl) { [bool]$wizardDefaults.useRemoteWsl } else { $false }
  $useRemoteWsl = Read-YesNo -Prompt "Launch VS Code in Remote WSL mode?" -DefaultValue $remoteDefault
  Write-Info ("Remote WSL launch: {0}" -f ($(if ($useRemoteWsl) { "enabled" } else { "disabled" })))
  if ($useRemoteWsl) {
    $distros = @(Get-WslDistroList)
    Write-Info ("Detected WSL distros: {0}" -f (($distros | ForEach-Object { "'$_'" }) -join ", "))
    if ($distros.Count -eq 0) {
      throw "No WSL distro found. Install WSL or choose local mode."
    } elseif ($distros.Count -eq 1) {
      $wslDistro = $distros[0]
      Write-Info ("Using WSL distro (single detected): {0}" -f $wslDistro)
    } else {
      $idx = Read-ChoiceIndex -Title "Select WSL distro:" -Options $distros -DefaultIndex 0
      $wslDistro = $distros[$idx]
      Write-Info ("Using WSL distro: {0}" -f $wslDistro)
    }
  }
} elseif ($platformIsWindows) {
  Write-Info "WSL not detected. WSL-related options are skipped."
}

$codexRunInWsl = if ($platformIsWindows -and $wslAvailable) {
  $codexDefault = if ($null -ne $wizardDefaults.codexRunInWsl) { [bool]$wizardDefaults.codexRunInWsl } else { $useRemoteWsl }
  Read-YesNo -Prompt "Set Codex to run in WSL for this project?" -DefaultValue $codexDefault
} else {
  $false
}
Write-Info ("VS Code setting chatgpt.runCodexInWindowsSubsystemForLinux = {0}" -f $codexRunInWsl.ToString().ToLowerInvariant())
Write-Info "VS Code setting chatgpt.openOnStartup = true"
if ($codexRunInWsl -and -not $useRemoteWsl) {
  Write-Info "Codex-in-WSL is enabled while VS Code launch mode is local Windows."
}

$ignoreDefault = if ($null -ne $wizardDefaults.ignoreSessions) { [bool]$wizardDefaults.ignoreSessions } else { $true }
$ignoreSessions = Read-YesNo -Prompt "Ignore Codex chat sessions in gitignore?" -DefaultValue $ignoreDefault
Write-Info ("Launcher logging default: {0}" -f ($(if ($enableLoggingByDefault) { "enabled (debug mode)" } else { "disabled" })))

$settingsWrite = Set-VscodeChatGptSettings -RootPath $targetRoot -RunCodexInWsl $codexRunInWsl
if ($null -ne $settingsWrite.PreviousRunCodexInWsl -and $settingsWrite.PreviousRunCodexInWsl -ne $codexRunInWsl) {
  Write-Info "Codex WSL setting changed. If VS Code is already running, reload/restart may be required."
}

if ($launchMode -eq "workspace" -and -not [string]::IsNullOrWhiteSpace($workspaceRelativePath)) {
  $workspacePathForSettings = Join-Path $targetRoot $workspaceRelativePath
  $workspaceSettingsWrite = Set-CodeWorkspaceChatGptSettings -WorkspacePath $workspacePathForSettings -RunCodexInWsl $codexRunInWsl
  if ($workspaceSettingsWrite.Applied) {
    Write-Info ("Workspace settings updated in: {0}" -f $workspaceRelativePath)
    if ($null -ne $workspaceSettingsWrite.PreviousRunCodexInWsl -and $workspaceSettingsWrite.PreviousRunCodexInWsl -ne $codexRunInWsl) {
      Write-Info "Workspace Codex WSL setting changed."
    }
  } else {
    Write-Info ("Workspace settings were not updated: {0}" -f $workspaceSettingsWrite.Reason)
  }
}

Save-WizardDefaults -DefaultsPath $defaultsInfo.Path -UseRemoteWsl $useRemoteWsl -CodexRunInWsl $codexRunInWsl -IgnoreSessions $ignoreSessions
Remove-LegacyGeneratedArtifacts -RootPath $targetRoot -LauncherBaseName $launcherBaseName
Update-GitIgnoreBlock `
  -RootPath $targetRoot `
  -IgnoreSessions $ignoreSessions `
  -LauncherFileName $launcherFileName `
  -MetadataDirName $metadataDirName

$outputs = if ($platformIsWindows) {
  New-WindowsLauncherFile `
    -RootPath $targetRoot `
    -LauncherBaseName $launcherBaseName `
    -MetadataDirName $metadataDirName `
    -LaunchMode $launchMode `
    -WorkspaceRelativePath $workspaceRelativePath `
    -UseRemoteWsl $useRemoteWsl `
    -WslDistro $wslDistro `
    -CodexRunInWsl $codexRunInWsl `
    -EnableLoggingByDefault $enableLoggingByDefault
} else {
  New-UnixLauncherFile `
    -RootPath $targetRoot `
    -LauncherBaseName $launcherBaseName `
    -MetadataDirName $metadataDirName `
    -LaunchMode $launchMode `
    -WorkspaceRelativePath $workspaceRelativePath `
    -EnableLoggingByDefault $enableLoggingByDefault
}

Write-Host ""
Write-Host "Launcher generated successfully."
foreach ($item in $outputs.GetEnumerator()) {
  Write-Host ("- {0}: {1}" -f $item.Key, $item.Value)
}
