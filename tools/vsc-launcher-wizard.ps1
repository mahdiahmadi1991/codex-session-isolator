param(
  [string]$TargetPath,
  [switch]$DebugMode,
  [switch]$Rollback,
  [switch]$RollbackRemoveCodexRuntimeData,
  [ValidateSet("Prompt", "Stop", "DeletePermanently")]
  [string]$RollbackDeleteBehavior = "Prompt"
)

$ErrorActionPreference = "Stop"
$script:WizardLogPath = $null
$script:BackupSessionId = $null
$script:BackupRootPath = $null
$script:BackupPathIndex = @{}

function Get-LogTimestamp {
  return (Get-Date).ToUniversalTime().ToString("o")
}

function Write-Log {
  param(
    [ValidateSet("INFO", "WARN", "ERROR")]
    [string]$Level = "INFO",
    [string]$Message
  )

  $line = "{0} [{1}] [wizard] {2}" -f (Get-LogTimestamp), $Level, $Message
  Write-Host $line
  if (-not [string]::IsNullOrWhiteSpace($script:WizardLogPath)) {
    Add-Content -LiteralPath $script:WizardLogPath -Value $line
  }
}

function Write-Info {
  param([string]$Message)
  Write-Log -Level "INFO" -Message $Message
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

function Test-IsWslUncPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  return $Path -match '^[\\]{2}(?:wsl\.localhost|wsl\$)[\\]'
}

function Test-IsWslLinuxEnvironment {
  if ($env:OS -eq "Windows_NT") {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($env:WSL_DISTRO_NAME)) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($env:WSL_INTEROP)) {
    return $false
  }

  return $true
}

function Get-WslDistroHintFromTargetPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  $trimmed = ($Path -replace [string][char]0, "").Trim()
  if ($trimmed -match '^[\\]{2}(?:wsl\.localhost|wsl\$)[\\]([^\\]+)[\\]') {
    return (Normalize-WslName -Name $Matches[1])
  }

  if ($trimmed -match '^/' -and -not [string]::IsNullOrWhiteSpace($env:WSL_DISTRO_NAME)) {
    return (Normalize-WslName -Name $env:WSL_DISTRO_NAME)
  }

  return ""
}

function Escape-BashSingleQuoted {
  param([string]$Value)

  $separator = "'" + '"' + "'" + '"' + "'"
  return [string]::Join($separator, ($Value -split "'"))
}

function Convert-LinuxPathToWindowsPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  if ($env:OS -eq "Windows_NT") {
    return $Path
  }

  try {
    $wslpathCommand = Get-Command wslpath -ErrorAction SilentlyContinue
    if ($null -eq $wslpathCommand) {
      return ""
    }

    $windowsPath = (& $wslpathCommand.Source -w $Path 2>$null | Out-String).Trim()
    return $windowsPath
  } catch {
    return ""
  }
}

function Convert-WindowsPathToLinuxPath {
  param(
    [string]$InputPath,
    [string]$Distro
  )

  if ($InputPath -match '^[\\]{2}(?:wsl\.localhost|wsl\$)[\\]([^\\]+)[\\](.*)$') {
    $distroInPath = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($Distro) -or $distroInPath -ieq $Distro) {
      $rest = $Matches[2] -replace '\\', '/'
      return "/$rest"
    }
    throw "WSL path '$InputPath' belongs to distro '$distroInPath', but launcher is configured for distro '$Distro'."
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
  $wslArgs = @()
  if ([string]::IsNullOrWhiteSpace($Distro)) {
    $wslArgs = @("--", "wslpath", "-a", "-u", $normalized)
  } else {
    $wslArgs = @("-d", $Distro, "--", "wslpath", "-a", "-u", $normalized)
  }
  $convertedRaw = & wsl.exe @wslArgs 2>&1
  $converted = ($convertedRaw | Out-String).Trim()
  $distroLabel = if ([string]::IsNullOrWhiteSpace($Distro)) { "<default>" } else { $Distro }
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
    throw "Failed to convert path '$InputPath' to Linux path in distro '$distroLabel'. wslpath: $converted"
  }
  return $converted
}

function Join-WindowsPath {
  param(
    [string]$BasePath,
    [string]$Leaf
  )

  if ([string]::IsNullOrWhiteSpace($BasePath)) {
    return $Leaf
  }
  if ([string]::IsNullOrWhiteSpace($Leaf)) {
    return $BasePath
  }

  return ($BasePath.TrimEnd('\', '/') + "\" + $Leaf)
}

function Get-WindowsDesktopPath {
  if ($env:OS -eq "Windows_NT") {
    try {
      return [Environment]::GetFolderPath("Desktop")
    } catch {
      return ""
    }
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $desktopRaw = & powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" 2>$null
    return (($desktopRaw | Out-String).Trim())
  } catch {
    return ""
  }
}

function Get-WindowsStartMenuProgramsPath {
  if ($env:OS -eq "Windows_NT") {
    try {
      return [Environment]::GetFolderPath("Programs")
    } catch {
      return ""
    }
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $pathRaw = & powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Programs')" 2>$null
    return (($pathRaw | Out-String).Trim())
  } catch {
    return ""
  }
}

function Get-WindowsWslIconLocation {
  if ($env:OS -eq "Windows_NT") {
    $candidate = Join-Path $env:SystemRoot "System32\wsl.exe"
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return "$candidate,0"
    }
    return ""
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $pathRaw = & powershell.exe -NoProfile -Command '$candidate = Join-Path $env:SystemRoot "System32\wsl.exe"; if (Test-Path -LiteralPath $candidate -PathType Leaf) { Write-Output $candidate }' 2>$null
    $candidate = (($pathRaw | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      return ""
    }
    return "$candidate,0"
  } catch {
    return ""
  }
}

function Get-WindowsWslExecutablePath {
  if ($env:OS -eq "Windows_NT") {
    $candidate = Join-Path $env:SystemRoot "System32\wsl.exe"
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
    return "wsl.exe"
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $pathRaw = & powershell.exe -NoProfile -Command '$candidate = Join-Path $env:SystemRoot "System32\wsl.exe"; if (Test-Path -LiteralPath $candidate -PathType Leaf) { Write-Output $candidate }' 2>$null
    $candidate = (($pathRaw | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      return "wsl.exe"
    }
    return $candidate
  } catch {
    return "wsl.exe"
  }
}

function Get-WindowsCmdExecutablePath {
  if ($env:OS -eq "Windows_NT") {
    $candidate = Join-Path $env:SystemRoot "System32\cmd.exe"
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
    return "cmd.exe"
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $pathRaw = & powershell.exe -NoProfile -Command '$candidate = Join-Path $env:SystemRoot "System32\cmd.exe"; if (Test-Path -LiteralPath $candidate -PathType Leaf) { Write-Output $candidate }' 2>$null
    $candidate = (($pathRaw | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      return "cmd.exe"
    }
    return $candidate
  } catch {
    return "cmd.exe"
  }
}

function Resolve-LinuxUserForWslShortcut {
  param([string]$LinuxProjectRoot)

  $normalized = (($LinuxProjectRoot -replace [string][char]0, "").Trim())
  if (-not [string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = $normalized -replace "\\", "/"
    if ($normalized -match '^/home/([^/]+)(?:/|$)') {
      return $Matches[1]
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USER)) {
    return (($env:USER -replace [string][char]0, "").Trim())
  }

  return ""
}

function Get-WindowsVsCodeIconLocation {
  if ($env:OS -eq "Windows_NT") {
    $candidates = @(
      (Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"),
      (Join-Path $env:ProgramFiles "Microsoft VS Code\Code.exe"),
      (Join-Path ${env:ProgramFiles(x86)} "Microsoft VS Code\Code.exe")
    )
    foreach ($candidate in $candidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return "$candidate,0"
      }
    }
    return (Get-WindowsWslIconLocation)
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return ""
  }

  try {
    $iconRaw = & powershell.exe -NoProfile -Command @'
$candidates = @()
$candidates += Join-Path $env:LocalAppData "Programs\Microsoft VS Code\Code.exe"
$candidates += Join-Path $env:ProgramFiles "Microsoft VS Code\Code.exe"
$candidates += Join-Path ${env:ProgramFiles(x86)} "Microsoft VS Code\Code.exe"
$candidates += Join-Path $env:LocalAppData "Programs\Microsoft VS Code Insiders\Code - Insiders.exe"
$candidates += Join-Path $env:ProgramFiles "Microsoft VS Code Insiders\Code - Insiders.exe"
foreach ($candidate in $candidates) {
  if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    Write-Output $candidate
    break
  }
}
'@ 2>$null
    $iconPath = (($iconRaw | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($iconPath)) {
      return (Get-WindowsWslIconLocation)
    }
    return "$iconPath,0"
  } catch {
    return (Get-WindowsWslIconLocation)
  }
}

function New-WindowsShortcutFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ShortcutPath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [string]$Arguments = "",
    [string]$WorkingDirectory = "",
    [string]$Description = "",
    [string]$IconLocation = ""
  )

  if ($env:OS -eq "Windows_NT") {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
      $shortcut.Arguments = $Arguments
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
      $shortcut.Description = $Description
    }
    if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
      $shortcut.IconLocation = $IconLocation
    }
    $shortcut.Save()
    return
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    throw "Windows shortcut generation is only supported on Windows or WSL."
  }

  $tempScriptLinux = Join-Path "/tmp" ("csi-shortcut-" + [Guid]::NewGuid().ToString("N") + ".ps1")
  $tempScriptWindows = Convert-LinuxPathToWindowsPath -Path $tempScriptLinux
  if ([string]::IsNullOrWhiteSpace($tempScriptWindows)) {
    throw "Failed to convert temporary shortcut script path to Windows path."
  }

  $scriptContent = @'
param(
  [Parameter(Mandatory = $true)][string]$ShortcutPath,
  [Parameter(Mandatory = $true)][string]$TargetPath,
  [string]$Arguments = "",
  [string]$WorkingDirectory = "",
  [string]$Description = "",
  [string]$IconLocation = ""
)

$ErrorActionPreference = "Stop"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $TargetPath
if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
  $shortcut.Arguments = $Arguments
}
if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
  $shortcut.WorkingDirectory = $WorkingDirectory
}
if (-not [string]::IsNullOrWhiteSpace($Description)) {
  $shortcut.Description = $Description
}
if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
  $shortcut.IconLocation = $IconLocation
}
$shortcut.Save()
'@

  try {
    Set-Content -LiteralPath $tempScriptLinux -Value $scriptContent
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScriptWindows `
      -ShortcutPath $ShortcutPath `
      -TargetPath $TargetPath `
      -Arguments $Arguments `
      -WorkingDirectory $WorkingDirectory `
      -Description $Description `
      -IconLocation $IconLocation 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "powershell.exe failed while generating Windows shortcut."
    }
  } finally {
    if (Test-Path -LiteralPath $tempScriptLinux -PathType Leaf) {
      Remove-Item -LiteralPath $tempScriptLinux -Force -ErrorAction SilentlyContinue
    }
  }
}

function Ensure-WindowsDirectoryPath {
  param([string]$DirectoryPath)

  if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
    return $false
  }

  if ($env:OS -eq "Windows_NT") {
    try {
      New-Item -ItemType Directory -Force -Path $DirectoryPath | Out-Null
      return $true
    } catch {
      return $false
    }
  }

  if (-not (Test-IsWslLinuxEnvironment)) {
    return $false
  }

  try {
    $escaped = $DirectoryPath -replace "'", "''"
    $null = & powershell.exe -NoProfile -Command ("New-Item -ItemType Directory -Force -Path '{0}' | Out-Null" -f $escaped) 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Resolve-WindowsShortcutDirectoryPath {
  param(
    [string]$LocationKey,
    [string]$TargetRoot,
    [string]$CustomPath
  )

  switch ($LocationKey) {
    "projectRoot" {
      if ($env:OS -eq "Windows_NT") {
        return $TargetRoot
      }
      return (Convert-LinuxPathToWindowsPath -Path $TargetRoot)
    }
    "desktop" {
      return (Get-WindowsDesktopPath)
    }
    "startMenu" {
      return (Get-WindowsStartMenuProgramsPath)
    }
    "custom" {
      $raw = ""
      if ($null -ne $CustomPath) {
        $raw = [string]$CustomPath
      }
      $raw = $raw.Trim()
      if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
      }
      if ($raw -match '^[A-Za-z]:[\\/]') {
        return ($raw -replace '/', '\')
      }
      if ($raw.StartsWith("\\")) {
        return $raw
      }
      if ($raw.StartsWith("/")) {
        return (Convert-LinuxPathToWindowsPath -Path $raw)
      }

      if ($env:OS -eq "Windows_NT") {
        return (Join-Path $TargetRoot $raw)
      }

      $relativeOnLinux = Join-Path $TargetRoot $raw
      return (Convert-LinuxPathToWindowsPath -Path $relativeOnLinux)
    }
    default {
      return ""
    }
  }
}

function Get-RelativePathSafe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

  $baseResolvedInfo = Resolve-Path -LiteralPath $BasePath -ErrorAction Stop | Select-Object -First 1
  $targetResolvedInfo = Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop | Select-Object -First 1
  $baseResolved = [IO.Path]::GetFullPath($baseResolvedInfo.ProviderPath)
  $targetResolved = [IO.Path]::GetFullPath($targetResolvedInfo.ProviderPath)

  $method = [IO.Path].GetMethod("GetRelativePath", [Type[]]@([string], [string]))
  if ($null -ne $method) {
    return [IO.Path]::GetRelativePath($baseResolved, $targetResolved)
  }

  $comparison = if ($env:OS -eq "Windows_NT") {
    [StringComparison]::OrdinalIgnoreCase
  } else {
    [StringComparison]::Ordinal
  }

  $baseRoot = [IO.Path]::GetPathRoot($baseResolved)
  $targetRoot = [IO.Path]::GetPathRoot($targetResolved)
  if ([string]::IsNullOrWhiteSpace($baseRoot) -or [string]::IsNullOrWhiteSpace($targetRoot)) {
    return $targetResolved
  }

  if (-not $baseRoot.Equals($targetRoot, $comparison)) {
    return $targetResolved
  }

  $baseRemainder = $baseResolved.Substring($baseRoot.Length).Trim('\', '/')
  $targetRemainder = $targetResolved.Substring($targetRoot.Length).Trim('\', '/')

  $baseSegments = @()
  if (-not [string]::IsNullOrWhiteSpace($baseRemainder)) {
    $baseSegments = @($baseRemainder -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  $targetSegments = @()
  if (-not [string]::IsNullOrWhiteSpace($targetRemainder)) {
    $targetSegments = @($targetRemainder -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  $commonLength = 0
  $maxLength = [Math]::Min($baseSegments.Count, $targetSegments.Count)
  while ($commonLength -lt $maxLength -and $baseSegments[$commonLength].Equals($targetSegments[$commonLength], $comparison)) {
    $commonLength++
  }

  $relativeSegments = New-Object System.Collections.Generic.List[string]
  for ($i = $commonLength; $i -lt $baseSegments.Count; $i++) {
    $relativeSegments.Add("..")
  }
  for ($i = $commonLength; $i -lt $targetSegments.Count; $i++) {
    $relativeSegments.Add($targetSegments[$i])
  }

  if ($relativeSegments.Count -eq 0) {
    return "."
  }

  return [string]::Join([IO.Path]::DirectorySeparatorChar, $relativeSegments)
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

function Get-PreferredLineEnding {
  param([string]$Text)

  if ($Text -match "`r`n") {
    return "`r`n"
  }

  return "`n"
}

function Write-Utf8NoBomText {
  param(
    [string]$Path,
    [string]$Content,
    [string]$ReferenceText = ""
  )

  $lineEnding = Get-PreferredLineEnding -Text $ReferenceText
  $normalized = if ($null -eq $Content) { "" } else { [string]$Content }
  $normalized = [regex]::Replace($normalized, "`r`n|`r|`n", $lineEnding)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

function Copy-HashtableDeep {
  param($InputObject)

  if ($null -eq $InputObject) {
    return $null
  }

  $roundTripped = $InputObject | ConvertTo-Json -Depth 50 | ConvertFrom-Json
  return Convert-ToHashtable -InputObject $roundTripped
}

function Test-StructuredDataEquivalent {
  param(
    $Left,
    $Right
  )

  $leftJson = $Left | ConvertTo-Json -Depth 50 -Compress
  $rightJson = $Right | ConvertTo-Json -Depth 50 -Compress
  return $leftJson -eq $rightJson
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

function Set-HiddenDotPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Any)) {
    return
  }

  $leaf = Split-Path -Leaf $Path
  if ([string]::IsNullOrWhiteSpace($leaf) -or -not $leaf.StartsWith(".")) {
    return
  }

  if ($env:OS -eq "Windows_NT") {
    try {
      $item = Get-Item -LiteralPath $Path -Force
      if (-not ($item.Attributes -band [IO.FileAttributes]::Hidden)) {
        $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
      }
    } catch {
      Write-Info ("Unable to set hidden attribute for path: {0}" -f $Path)
    }
    return
  }

  # WSL fallback: allow hidden attribute on Windows-mounted paths when wizard runs in Linux.
  if ($Path -notmatch '^/mnt/[a-zA-Z]/') {
    return
  }

  try {
    $wslpathCommand = Get-Command wslpath -ErrorAction SilentlyContinue
    $attribCommand = Get-Command attrib.exe -ErrorAction SilentlyContinue
    if ($null -eq $wslpathCommand -or $null -eq $attribCommand) {
      return
    }

    $windowsPath = (& $wslpathCommand.Source -w $Path 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($windowsPath)) {
      return
    }

    & $attribCommand.Source +h $windowsPath 2>$null | Out-Null
  } catch {
    Write-Info ("Unable to set hidden attribute for path: {0}" -f $Path)
  }
}

function Ensure-Directory {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return $false
  }

  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return $true
}

function Resolve-FullPathSafe {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  if (Test-Path -LiteralPath $Path -PathType Any) {
    return [IO.Path]::GetFullPath((Get-Item -LiteralPath $Path -Force).FullName)
  }

  return [IO.Path]::GetFullPath($Path)
}

function Test-PathUnderRoot {
  param(
    [string]$RootPath,
    [string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace($RootPath) -or [string]::IsNullOrWhiteSpace($TargetPath)) {
    return $false
  }

  $fullRoot = Resolve-FullPathSafe -Path $RootPath
  $fullTarget = Resolve-FullPathSafe -Path $TargetPath
  if ([string]::IsNullOrWhiteSpace($fullRoot) -or [string]::IsNullOrWhiteSpace($fullTarget)) {
    return $false
  }

  $comparison = if ($env:OS -eq "Windows_NT") {
    [StringComparison]::OrdinalIgnoreCase
  } else {
    [StringComparison]::Ordinal
  }

  if ($fullTarget.Equals($fullRoot, $comparison)) {
    return $true
  }

  $rootWithSeparator = $fullRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  return $fullTarget.StartsWith($rootWithSeparator, $comparison)
}

function Get-BackupRecordForPath {
  param([string]$Path)

  $fullPath = Resolve-FullPathSafe -Path $Path
  if ([string]::IsNullOrWhiteSpace($fullPath)) {
    return $null
  }

  if ($script:BackupPathIndex.ContainsKey($fullPath)) {
    return $script:BackupPathIndex[$fullPath]
  }

  return $null
}

function Convert-ToPortableRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  return ($Path -replace '\\', '/')
}

function New-ManagedPathRecord {
  param(
    [string]$Path,
    [string]$RootPath,
    [string]$Kind = "file",
    [Nullable[bool]]$ExistedBeforeSetup = $null,
    [Nullable[bool]]$ExistsAfterSetup = $null
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $fullPath = Resolve-FullPathSafe -Path $Path
  $backupRecord = Get-BackupRecordForPath -Path $Path
  $pathUnderRoot = Test-PathUnderRoot -RootPath $RootPath -TargetPath $fullPath
  $projectRelativePath = $null
  if ($pathUnderRoot) {
    $projectRelativePath = Convert-ToPortableRelativePath -Path (Get-RelativePathSafe -BasePath $RootPath -TargetPath $fullPath)
  }

  $existsAfter = if ($null -ne $ExistsAfterSetup) {
    [bool]$ExistsAfterSetup
  } else {
    Test-Path -LiteralPath $Path -PathType Any
  }

  $existedBefore = if ($null -ne $ExistedBeforeSetup) {
    [bool]$ExistedBeforeSetup
  } else {
    ($null -ne $backupRecord)
  }

  return [ordered]@{
    kind = $Kind
    pathScope = if ($pathUnderRoot) { "project" } else { "external" }
    projectRelativePath = if ($pathUnderRoot) { $projectRelativePath } else { $null }
    absolutePath = if ($pathUnderRoot) { $null } else { $fullPath }
    existedBeforeSetup = $existedBefore
    existsAfterSetup = $existsAfter
    hadBackup = ($null -ne $backupRecord)
    backupRelativePath = if ($null -ne $backupRecord) { $backupRecord.BackupRelativePath } else { $null }
  }
}

function Merge-Hashtable {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Base,
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Additional
  )

  $merged = [ordered]@{}
  foreach ($key in $Base.Keys) {
    $merged[$key] = $Base[$key]
  }
  foreach ($key in $Additional.Keys) {
    $merged[$key] = $Additional[$key]
  }
  return $merged
}

function Save-RollbackManifest {
  param(
    [string]$RootPath,
    [string]$MetadataDirName,
    [System.Collections.IDictionary]$Manifest
  )

  $metadataDirPath = Join-Path $RootPath $MetadataDirName
  $manifestPath = Join-Path $metadataDirPath "rollback.manifest.json"
  $null = Ensure-Directory -Path $metadataDirPath
  Backup-PathIfExists -Path $manifestPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  Set-Content -LiteralPath $manifestPath -Value ($Manifest | ConvertTo-Json -Depth 50)
  return $manifestPath
}

function Resolve-ManifestProjectPath {
  param(
    [string]$RootPath,
    [string]$PortableRelativePath
  )

  if ([string]::IsNullOrWhiteSpace($PortableRelativePath)) {
    return ""
  }

  $nativeRelativePath = $PortableRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar
  return Join-Path $RootPath $nativeRelativePath
}

function Get-ManifestRecordPath {
  param(
    [string]$RootPath,
    $Record
  )

  if ($null -eq $Record) {
    return ""
  }

  if ($Record.pathScope -eq "project") {
    return Resolve-ManifestProjectPath -RootPath $RootPath -PortableRelativePath ([string]$Record.projectRelativePath)
  }

  return [string]$Record.absolutePath
}

function Get-ManifestRecordBackupPath {
  param(
    [string]$RootPath,
    $Manifest,
    $Record
  )

  if ($null -eq $Record -or -not [bool]$Record.hadBackup) {
    return ""
  }

  $backupRootRelativePath = [string]$Manifest.latestBackupProjectRelativePath
  $backupRelativePath = [string]$Record.backupRelativePath
  if ([string]::IsNullOrWhiteSpace($backupRootRelativePath) -or [string]::IsNullOrWhiteSpace($backupRelativePath)) {
    return ""
  }

  $backupRootPath = Resolve-ManifestProjectPath -RootPath $RootPath -PortableRelativePath $backupRootRelativePath
  return Resolve-ManifestProjectPath -RootPath $backupRootPath -PortableRelativePath $backupRelativePath
}

function Read-JsonObjectStrict {
  param(
    [string]$Path,
    [string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Description not found: $Path"
  }

  try {
    $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$Description is not valid JSON and cannot be rolled back safely: $Path"
  }

  if ($obj -is [System.Collections.IDictionary]) {
    return (Convert-ToHashtable -InputObject $obj)
  }

  return (Convert-ToHashtable -InputObject $obj)
}

function Test-IsMacOsPlatform {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
}

function Get-UniqueSiblingPath {
  param([string]$CandidatePath)

  if (-not (Test-Path -LiteralPath $CandidatePath -PathType Any)) {
    return $CandidatePath
  }

  $parent = Split-Path -Parent $CandidatePath
  $leaf = Split-Path -Leaf $CandidatePath
  $name = [IO.Path]::GetFileNameWithoutExtension($leaf)
  $extension = [IO.Path]::GetExtension($leaf)
  $counter = 1
  while ($true) {
    $nextLeaf = "{0}-{1}{2}" -f $name, $counter, $extension
    $nextPath = Join-Path $parent $nextLeaf
    if (-not (Test-Path -LiteralPath $nextPath -PathType Any)) {
      return $nextPath
    }
    $counter++
  }
}

function Test-CanUseNativeTrashForPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Any)) {
    return $false
  }

  if ($env:OS -eq "Windows_NT") {
    if (Test-IsWslUncPath -Path $Path) {
      return $false
    }

    if ($Path -match '^[\\]{2}') {
      return $false
    }

    return $true
  }

  if (Test-IsMacOsPlatform) {
    return (-not [string]::IsNullOrWhiteSpace($HOME))
  }

  return (-not [string]::IsNullOrWhiteSpace($HOME))
}

function Move-PathToWindowsRecycleBin {
  param([string]$Path)

  Add-Type -AssemblyName Microsoft.VisualBasic
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.PSIsContainer) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
      $Path,
      [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
      [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    )
    return
  }

  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
    $Path,
    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
  )
}

function Move-PathToMacTrash {
  param([string]$Path)

  $trashDir = Join-Path $HOME ".Trash"
  $null = Ensure-Directory -Path $trashDir
  $destination = Get-UniqueSiblingPath -CandidatePath (Join-Path $trashDir (Split-Path -Leaf $Path))
  Move-Item -LiteralPath $Path -Destination $destination -Force
}

function Get-LinuxTrashInfoPathValue {
  param([string]$OriginalPath)

  $portablePath = Convert-ToPortableRelativePath -Path $OriginalPath
  $escapedPath = $portablePath.Replace('%', '%25')
  $escapedPath = $escapedPath.Replace("`r", '%0D')
  $escapedPath = $escapedPath.Replace("`n", '%0A')
  return $escapedPath
}

function Move-PathToLinuxTrash {
  param([string]$Path)

  $xdgDataHome = if (-not [string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
    $env:XDG_DATA_HOME
  } else {
    Join-Path $HOME ".local/share"
  }

  $trashRoot = Join-Path $xdgDataHome "Trash"
  $trashFilesDir = Join-Path $trashRoot "files"
  $trashInfoDir = Join-Path $trashRoot "info"
  $null = Ensure-Directory -Path $trashFilesDir
  $null = Ensure-Directory -Path $trashInfoDir

  $leaf = Split-Path -Leaf $Path
  $trashTarget = Get-UniqueSiblingPath -CandidatePath (Join-Path $trashFilesDir $leaf)
  $trashInfoTarget = Join-Path $trashInfoDir ((Split-Path -Leaf $trashTarget) + ".trashinfo")
  $trashInfoTarget = Get-UniqueSiblingPath -CandidatePath $trashInfoTarget

  Move-Item -LiteralPath $Path -Destination $trashTarget -Force

  $trashInfo = @(
    "[Trash Info]"
    ("Path={0}" -f (Get-LinuxTrashInfoPathValue -OriginalPath (Resolve-FullPathSafe -Path $Path)))
    ("DeletionDate={0}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"))
    ""
  ) -join "`n"
  [System.IO.File]::WriteAllText($trashInfoTarget, $trashInfo, (New-Object System.Text.UTF8Encoding($false)))
}

function Move-PathToNativeTrash {
  param([string]$Path)

  if ($env:OS -eq "Windows_NT") {
    Move-PathToWindowsRecycleBin -Path $Path
    return
  }

  if (Test-IsMacOsPlatform) {
    Move-PathToMacTrash -Path $Path
    return
  }

  Move-PathToLinuxTrash -Path $Path
}

function Remove-PathPermanently {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Any)) {
    return
  }

  $isIgnorableMissingPathError = {
    param($Exception)

    if ($null -eq $Exception) {
      return $false
    }

    $message = [string]$Exception.Message
    if ($message -match "Could not find a part of the path") {
      return $true
    }

    if ($message -match "Cannot find path") {
      return $true
    }

    if ($message -match "because it does not exist") {
      return $true
    }

    return $false
  }

  try {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    return
  } catch {
    if (-not (Test-Path -LiteralPath $Path -PathType Any)) {
      return
    }
  }

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
      [System.IO.File]::Delete($Path)
      return
    }

    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
      Remove-PathPermanently -Path $child.FullName
    }

    if (Test-Path -LiteralPath $Path -PathType Any) {
      $remainingChildren = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
      foreach ($remainingChild in $remainingChildren) {
        Remove-PathPermanently -Path $remainingChild.FullName
      }

      if (Test-Path -LiteralPath $Path -PathType Any) {
        [System.IO.Directory]::Delete($Path, $true)
      }
    }
  } catch {
    if (-not (Test-Path -LiteralPath $Path -PathType Any)) {
      return
    }

    if (& $isIgnorableMissingPathError $_.Exception) {
      return
    }

    throw
  }
}

function Ensure-ParentDirectoryForPath {
  param([string]$Path)

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    $null = Ensure-Directory -Path $parent
  }
}

function Restore-PathFromBackup {
  param(
    [string]$BackupPath,
    [string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace($BackupPath) -or -not (Test-Path -LiteralPath $BackupPath -PathType Any)) {
    throw "Required backup source is missing: $BackupPath"
  }

  Ensure-ParentDirectoryForPath -Path $TargetPath
  $backupItem = Get-Item -LiteralPath $BackupPath -Force
  if ($backupItem.PSIsContainer) {
    Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Recurse -Force
  } else {
    Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
  }
}

function Remove-ManagedGitIgnoreBlockCurrent {
  param($Record, [string]$Path)

  if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  $startMarker = [string]$Record.startMarker
  $endMarker = [string]$Record.endMarker
  if ([string]::IsNullOrWhiteSpace($startMarker) -or [string]::IsNullOrWhiteSpace($endMarker)) {
    throw "Rollback manifest is missing managed .gitignore markers."
  }

  $current = Get-Content -LiteralPath $Path -Raw
  $pattern = "(?ms)(?:\r?\n)?^" + [regex]::Escape($startMarker) + ".*?^" + [regex]::Escape($endMarker) + "\s*"
  if ($current -notmatch $pattern) {
    return $false
  }

  $updated = [regex]::Replace($current, $pattern, "")
  Write-Utf8NoBomText -Path $Path -Content $updated -ReferenceText $current
  return $true
}

function Get-ManagedKeyBackupValue {
  param(
    [hashtable]$BackupObject,
    [string]$KeyName
  )

  if ($null -eq $BackupObject) {
    return @{
      Exists = $false
      Value = $null
    }
  }

  if ($BackupObject.Contains($KeyName)) {
    return @{
      Exists = $true
      Value = $BackupObject[$KeyName]
    }
  }

  return @{
    Exists = $false
    Value = $null
  }
}

function Invoke-RollbackVscodeSettings {
  param(
    [string]$RootPath,
    $Manifest,
    $Record,
    [ref]$Warnings,
    [ref]$RemovalRequests
  )

  $path = Get-ManifestRecordPath -RootPath $RootPath -Record $Record
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return
  }

  $rawCurrentText = Get-Content -LiteralPath $path -Raw
  $current = Read-JsonObjectStrict -Path $path -Description "Current VS Code settings file"
  $backup = $null
  $backupPath = ""
  if ([bool]$Record.hadBackup) {
    $backupPath = Get-ManifestRecordBackupPath -RootPath $RootPath -Manifest $Manifest -Record $Record
    $backup = Read-JsonObjectStrict -Path $backupPath -Description "Backed-up VS Code settings file"
  }

  $normalizedCurrent = Copy-HashtableDeep -InputObject $current

  foreach ($prop in $Record.managedKeys.PSObject.Properties) {
    $keyName = $prop.Name
    $keyRecord = $prop.Value
    if (-not $current.Contains($keyName)) {
      continue
    }

    $currentValue = $current[$keyName]
    if ($currentValue -ne $keyRecord.appliedValue) {
      $Warnings.Value += ("Skipped VS Code setting rollback for '{0}' because the user changed it after setup." -f $keyName)
      continue
    }

    if ([bool]$keyRecord.existedBeforeSetup) {
      $backupValue = Get-ManagedKeyBackupValue -BackupObject $backup -KeyName $keyName
      if (-not [bool]$backupValue.Exists) {
        throw "Rollback metadata expects a previous value for '$keyName' in VS Code settings, but the backup does not contain it."
      }
      $current[$keyName] = $backupValue.Value
      if ($null -ne $normalizedCurrent) {
        $normalizedCurrent[$keyName] = $backupValue.Value
      }
    } else {
      $current.Remove($keyName)
      if ($null -ne $normalizedCurrent -and $normalizedCurrent.Contains($keyName)) {
        $normalizedCurrent.Remove($keyName)
      }
    }
  }

  if ($current.Count -eq 0 -and -not [bool]$Record.existedBeforeSetup) {
    $RemovalRequests.Value += @{
      Path = $path
      Reason = "VS Code settings file created by setup"
    }
    return
  }

  if ([bool]$Record.hadBackup -and -not [string]::IsNullOrWhiteSpace($backupPath) -and $null -ne $backup -and (Test-StructuredDataEquivalent -Left $normalizedCurrent -Right $backup)) {
    Copy-Item -LiteralPath $backupPath -Destination $path -Force
    return
  }

  Write-Utf8NoBomText -Path $path -Content ($current | ConvertTo-Json -Depth 50) -ReferenceText $rawCurrentText
}

function Invoke-RollbackWorkspaceSettings {
  param(
    [string]$RootPath,
    $Manifest,
    $Record,
    [ref]$Warnings
  )

  $path = Get-ManifestRecordPath -RootPath $RootPath -Record $Record
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return
  }

  $rawCurrentText = Get-Content -LiteralPath $path -Raw
  $current = Read-JsonObjectStrict -Path $path -Description "Current workspace file"
  $currentSettings = if ($current.Contains("settings") -and $current["settings"] -is [System.Collections.IDictionary]) {
    Convert-ToHashtable -InputObject $current["settings"]
  } elseif ($current.Contains("settings") -and $null -ne $current["settings"]) {
    Convert-ToHashtable -InputObject $current["settings"]
  } else {
    [ordered]@{}
  }

  $backup = $null
  $backupSettings = $null
  $backupPath = ""
  if ([bool]$Record.hadBackup) {
    $backupPath = Get-ManifestRecordBackupPath -RootPath $RootPath -Manifest $Manifest -Record $Record
    $backup = Read-JsonObjectStrict -Path $backupPath -Description "Backed-up workspace file"
    if ($backup.Contains("settings") -and $null -ne $backup["settings"]) {
      $backupSettings = if ($backup["settings"] -is [System.Collections.IDictionary]) {
        Convert-ToHashtable -InputObject $backup["settings"]
      } else {
        Convert-ToHashtable -InputObject $backup["settings"]
      }
    } else {
      $backupSettings = [ordered]@{}
    }
  }

  $normalizedCurrent = Copy-HashtableDeep -InputObject $current
  $normalizedCurrentSettings = if ($null -ne $normalizedCurrent -and $normalizedCurrent.Contains("settings") -and $null -ne $normalizedCurrent["settings"]) {
    Convert-ToHashtable -InputObject $normalizedCurrent["settings"]
  } else {
    [ordered]@{}
  }

  foreach ($prop in $Record.managedKeys.PSObject.Properties) {
    $keyName = $prop.Name
    $keyRecord = $prop.Value
    if (-not $currentSettings.Contains($keyName)) {
      continue
    }

    $currentValue = $currentSettings[$keyName]
    if ($currentValue -ne $keyRecord.appliedValue) {
      $Warnings.Value += ("Skipped workspace setting rollback for '{0}' because the user changed it after setup." -f $keyName)
      continue
    }

    if ([bool]$keyRecord.existedBeforeSetup) {
      $backupValue = Get-ManagedKeyBackupValue -BackupObject $backupSettings -KeyName $keyName
      if (-not [bool]$backupValue.Exists) {
        throw "Rollback metadata expects a previous workspace value for '$keyName', but the backup does not contain it."
      }
      $currentSettings[$keyName] = $backupValue.Value
      $normalizedCurrentSettings[$keyName] = $backupValue.Value
    } else {
      $currentSettings.Remove($keyName)
      if ($normalizedCurrentSettings.Contains($keyName)) {
        $normalizedCurrentSettings.Remove($keyName)
      }
    }
  }

  if ($currentSettings.Count -eq 0) {
    $current.Remove("settings")
  } else {
    $current["settings"] = $currentSettings
  }

  if ($null -ne $normalizedCurrent) {
    if ($normalizedCurrentSettings.Count -eq 0) {
      $normalizedCurrent.Remove("settings")
    } else {
      $normalizedCurrent["settings"] = $normalizedCurrentSettings
    }
  }

  if ([bool]$Record.hadBackup -and -not [string]::IsNullOrWhiteSpace($backupPath) -and $null -ne $backup -and (Test-StructuredDataEquivalent -Left $normalizedCurrent -Right $backup)) {
    Copy-Item -LiteralPath $backupPath -Destination $path -Force
    return
  }

  Write-Utf8NoBomText -Path $path -Content ($current | ConvertTo-Json -Depth 50) -ReferenceText $rawCurrentText
}

function Resolve-RollbackFallbackChoice {
  param(
    [hashtable[]]$UnsupportedPaths,
    [string]$DeleteBehavior = "Prompt"
  )

  if ($UnsupportedPaths.Count -eq 0) {
    return $false
  }

  switch ($DeleteBehavior) {
    "Stop" {
      throw "Native Trash/Recycle Bin is not available for one or more required rollback paths."
    }
    "DeletePermanently" {
      return $true
    }
  }

  Write-Host ""
  Write-Host "Native Trash/Recycle Bin is not available for one or more rollback paths."
  foreach ($item in $UnsupportedPaths) {
    Write-Host ("- {0}" -f $item.Path)
  }
  $choice = Read-ChoiceIndex -Title "How do you want to continue?" -Options @("Stop rollback", "Delete permanently") -DefaultIndex 0
  if ($choice -eq 0) {
    throw "Native Trash/Recycle Bin is not available for one or more required rollback paths."
  }

  return $true
}

function Invoke-RollbackRemovalPreflight {
  param(
    [hashtable[]]$RemovalRequests,
    [ref]$AllowPermanentDeleteFallback,
    [string]$DeleteBehavior = "Prompt"
  )

  $existingRequests = @($RemovalRequests | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and (Test-Path -LiteralPath $_.Path -PathType Any) })
  if ($existingRequests.Count -eq 0) {
    return
  }

  $unsupported = @($existingRequests | Where-Object { -not (Test-CanUseNativeTrashForPath -Path $_.Path) })
  if ($unsupported.Count -gt 0 -and $null -eq $AllowPermanentDeleteFallback.Value) {
    $AllowPermanentDeleteFallback.Value = Resolve-RollbackFallbackChoice -UnsupportedPaths $unsupported -DeleteBehavior $DeleteBehavior
  }
}

function Invoke-RollbackRemoval {
  param(
    [hashtable[]]$RemovalRequests,
    [ref]$Summary,
    [ref]$AllowPermanentDeleteFallback,
    [string]$DeleteBehavior = "Prompt"
  )

  $existingRequests = @($RemovalRequests | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and (Test-Path -LiteralPath $_.Path -PathType Any) })
  if ($existingRequests.Count -eq 0) {
    return
  }

  $unsupported = @($existingRequests | Where-Object { -not (Test-CanUseNativeTrashForPath -Path $_.Path) })
  if ($unsupported.Count -gt 0 -and $null -eq $AllowPermanentDeleteFallback.Value) {
    $AllowPermanentDeleteFallback.Value = Resolve-RollbackFallbackChoice -UnsupportedPaths $unsupported -DeleteBehavior $DeleteBehavior
  }

  foreach ($request in $existingRequests) {
    $canTrash = Test-CanUseNativeTrashForPath -Path $request.Path
    if ($canTrash) {
      Move-PathToNativeTrash -Path $request.Path
      $Summary.Value.Trashed += 1
      continue
    }

    if (-not [bool]$AllowPermanentDeleteFallback.Value) {
      throw "Native Trash/Recycle Bin is not available for required rollback path: $($request.Path)"
    }

    Remove-PathPermanently -Path $request.Path
    $Summary.Value.PermanentlyDeleted += 1
  }
}

function Get-RollbackManifestContext {
  param(
    [string]$RootPath,
    [string]$MetadataDirName
  )

  $metadataDirPath = Join-Path $RootPath $MetadataDirName
  $manifestPath = Join-Path $metadataDirPath "rollback.manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    if (Test-Path -LiteralPath $metadataDirPath -PathType Container) {
      throw "This project was initialized before rollback metadata existed. Automatic rollback is not available for this target."
    }

    throw "No launcher-managed rollback metadata found for target: $RootPath"
  }

  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Rollback manifest is not valid JSON and cannot be used safely: $manifestPath"
  }

  if ($manifest.schemaVersion -ne 1) {
    throw "Rollback manifest schema version '$($manifest.schemaVersion)' is not supported."
  }

  return @{
    ManifestPath = $manifestPath
    MetadataDirPath = $metadataDirPath
    Manifest = $manifest
  }
}

function Get-CodexRuntimeCleanupPlan {
  param([string]$RootPath)

  $codexDirPath = Join-Path $RootPath ".codex"
  if (-not (Test-Path -LiteralPath $codexDirPath -PathType Container)) {
    return @{
      RemovalRequests = @()
      RemoveCodexDirectoryAfterCleanup = $false
    }
  }

  $removalRequests = @()
  $configPath = Join-Path $codexDirPath "config.toml"
  $preserveConfig = Test-Path -LiteralPath $configPath -PathType Leaf
  $children = @(Get-ChildItem -LiteralPath $codexDirPath -Force -ErrorAction SilentlyContinue)
  foreach ($child in $children) {
    if (-not $child.PSIsContainer -and $child.Name -ieq "config.toml") {
      continue
    }

    $removalRequests += @{
      Path = $child.FullName
      Reason = "Remove project Codex runtime data"
    }
  }

  return @{
    RemovalRequests = $removalRequests
    RemoveCodexDirectoryAfterCleanup = (($removalRequests.Count -gt 0) -and (-not $preserveConfig))
  }
}

function Invoke-RollbackForTarget {
  param(
    [string]$RootPath,
    [string]$MetadataDirName,
    [bool]$RemoveCodexRuntimeData = $false,
    [string]$DeleteBehavior = "Prompt"
  )

  $context = Get-RollbackManifestContext -RootPath $RootPath -MetadataDirName $MetadataDirName
  $manifest = $context.Manifest
  $warnings = @()
  $removalRequests = @()
  $restoreRequests = @()
  $allowPermanentDeleteFallback = $null
  $codexRuntimeCleanupPlan = if ($RemoveCodexRuntimeData) { Get-CodexRuntimeCleanupPlan -RootPath $RootPath } else { $null }
  $summary = @{
    Restored = 0
    Trashed = 0
    PermanentlyDeleted = 0
    Edited = 0
    Warnings = 0
  }

  $preserveMetadataDirForPreflight = [bool]$manifest.managedFiles.metadataDirectory.existedBeforeSetup
  foreach ($recordName in @("wizardDefaults", "launcherConfig", "launcherRunner")) {
    $record = $manifest.managedFiles.$recordName
    if ($null -ne $record -and [bool]$record.hadBackup) {
      $preserveMetadataDirForPreflight = $true
      break
    }
  }

  $preflightRemovalRequests = @()
  foreach ($recordName in @("launcher", "launcherConfig", "launcherRunner", "wizardDefaults", "windowsShortcut")) {
    $record = $manifest.managedFiles.$recordName
    if ($null -eq $record) {
      continue
    }

    $currentPath = Get-ManifestRecordPath -RootPath $RootPath -Record $record
    if (Test-Path -LiteralPath $currentPath -PathType Any) {
      $preflightRemovalRequests += @{
        Path = $currentPath
        Reason = "Potential rollback removal for launcher-owned artifact"
      }
    }
  }

  if ($null -ne $manifest.generatedWorkspace) {
    $generatedWorkspacePathForPreflight = Get-ManifestRecordPath -RootPath $RootPath -Record $manifest.generatedWorkspace
    if (Test-Path -LiteralPath $generatedWorkspacePathForPreflight -PathType Any) {
      $preflightRemovalRequests += @{
        Path = $generatedWorkspacePathForPreflight
        Reason = "Potential rollback removal for generated workspace"
      }
    }
  }

  if ($null -ne $manifest.managedFiles.vscodeSettings -and -not [bool]$manifest.managedFiles.vscodeSettings.existedBeforeSetup) {
    $vscodeSettingsPathForPreflight = Get-ManifestRecordPath -RootPath $RootPath -Record $manifest.managedFiles.vscodeSettings
    if (Test-Path -LiteralPath $vscodeSettingsPathForPreflight -PathType Any) {
      $preflightRemovalRequests += @{
        Path = $vscodeSettingsPathForPreflight
        Reason = "Potential rollback removal for VS Code settings created by setup"
      }
    }
  }

  $backupSessionPathForPreflight = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.latestBackupProjectRelativePath)) {
    Resolve-ManifestProjectPath -RootPath $RootPath -PortableRelativePath ([string]$manifest.latestBackupProjectRelativePath)
  } else {
    ""
  }

  if ($preserveMetadataDirForPreflight) {
    if (-not [string]::IsNullOrWhiteSpace($backupSessionPathForPreflight) -and (Test-Path -LiteralPath $backupSessionPathForPreflight -PathType Any)) {
      $preflightRemovalRequests += @{
        Path = $backupSessionPathForPreflight
        Reason = "Potential rollback removal for current backup session"
      }
    }

    if (Test-Path -LiteralPath $context.ManifestPath -PathType Leaf) {
      $preflightRemovalRequests += @{
        Path = $context.ManifestPath
        Reason = "Potential rollback removal for rollback manifest"
      }
    }
  } elseif (Test-Path -LiteralPath $context.MetadataDirPath -PathType Any) {
    $preflightRemovalRequests += @{
      Path = $context.MetadataDirPath
      Reason = "Potential rollback removal for metadata directory"
    }
  }

  if ($null -ne $codexRuntimeCleanupPlan) {
    $preflightRemovalRequests += @($codexRuntimeCleanupPlan.RemovalRequests)
    if ([bool]$codexRuntimeCleanupPlan.RemoveCodexDirectoryAfterCleanup) {
      $preflightRemovalRequests += @{
        Path = (Join-Path $RootPath ".codex")
        Reason = "Potential rollback removal for empty Codex runtime directory"
      }
    }
  }

  Invoke-RollbackRemovalPreflight -RemovalRequests $preflightRemovalRequests -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior

  if ($null -ne $manifest.managedFiles.vscodeSettings) {
    $beforeCount = $removalRequests.Count
    Invoke-RollbackVscodeSettings -RootPath $RootPath -Manifest $manifest -Record $manifest.managedFiles.vscodeSettings -Warnings ([ref]$warnings) -RemovalRequests ([ref]$removalRequests)
    $summary.Edited += 1
  }

  if ($null -ne $manifest.managedFiles.workspaceSettings) {
    if ($null -eq $manifest.generatedWorkspace) {
      Invoke-RollbackWorkspaceSettings -RootPath $RootPath -Manifest $manifest -Record $manifest.managedFiles.workspaceSettings -Warnings ([ref]$warnings)
      $summary.Edited += 1
    }
  }

  if ($null -ne $manifest.managedFiles.gitignore) {
    $gitignorePath = Get-ManifestRecordPath -RootPath $RootPath -Record $manifest.managedFiles.gitignore
    if (Remove-ManagedGitIgnoreBlockCurrent -Record $manifest.managedFiles.gitignore -Path $gitignorePath) {
      $summary.Edited += 1
    }
  }

  $preserveMetadataDir = [bool]$manifest.managedFiles.metadataDirectory.existedBeforeSetup
  foreach ($recordName in @("wizardDefaults", "launcherConfig", "launcherRunner")) {
    $record = $manifest.managedFiles.$recordName
    if ($null -ne $record -and [bool]$record.hadBackup) {
      $preserveMetadataDir = $true
      break
    }
  }

  foreach ($recordName in @("launcher", "launcherConfig", "launcherRunner", "wizardDefaults", "windowsShortcut")) {
    $record = $manifest.managedFiles.$recordName
    if ($null -eq $record) {
      continue
    }

    $currentPath = Get-ManifestRecordPath -RootPath $RootPath -Record $record
    $backupPath = Get-ManifestRecordBackupPath -RootPath $RootPath -Manifest $manifest -Record $record

    if ([bool]$record.hadBackup -and -not [string]::IsNullOrWhiteSpace($backupPath)) {
      if (Test-Path -LiteralPath $currentPath -PathType Any) {
        $removalRequests += @{
          Path = $currentPath
          Reason = "Replace current managed artifact with its pre-setup backup"
        }
      }

      $restoreRequests += @{
        TargetPath = $currentPath
        BackupPath = $backupPath
      }
      continue
    }

    if (Test-Path -LiteralPath $currentPath -PathType Any) {
      $removalRequests += @{
        Path = $currentPath
        Reason = "Remove launcher-owned artifact created by setup"
      }
    }
  }

  foreach ($record in @($manifest.removedDuringSetup)) {
    if ($null -eq $record -or -not [bool]$record.hadBackup) {
      continue
    }

    $targetPath = Get-ManifestRecordPath -RootPath $RootPath -Record $record
    if (Test-Path -LiteralPath $targetPath -PathType Any) {
      $warnings += ("Skipped restoring '{0}' because the path now exists and may contain user changes." -f $targetPath)
      continue
    }

    $backupPath = Get-ManifestRecordBackupPath -RootPath $RootPath -Manifest $manifest -Record $record
    $restoreRequests += @{
      TargetPath = $targetPath
      BackupPath = $backupPath
    }
  }

  if ($null -ne $codexRuntimeCleanupPlan) {
    $removalRequests += @($codexRuntimeCleanupPlan.RemovalRequests)
  }

  if ($null -ne $manifest.generatedWorkspace) {
    $generatedWorkspacePath = Get-ManifestRecordPath -RootPath $RootPath -Record $manifest.generatedWorkspace
    if (Test-Path -LiteralPath $generatedWorkspacePath -PathType Any) {
      $removalRequests += @{
        Path = $generatedWorkspacePath
        Reason = "Remove workspace file created by setup"
      }
    }
  }

  $backupSessionPath = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.latestBackupProjectRelativePath)) {
    Resolve-ManifestProjectPath -RootPath $RootPath -PortableRelativePath ([string]$manifest.latestBackupProjectRelativePath)
  } else {
    ""
  }

  Invoke-RollbackRemoval -RemovalRequests $removalRequests -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior

  foreach ($restore in $restoreRequests) {
    Restore-PathFromBackup -BackupPath $restore.BackupPath -TargetPath $restore.TargetPath
    $summary.Restored += 1
  }

  if ($null -ne $codexRuntimeCleanupPlan -and [bool]$codexRuntimeCleanupPlan.RemoveCodexDirectoryAfterCleanup) {
    $codexDirPath = Join-Path $RootPath ".codex"
    if (Test-Path -LiteralPath $codexDirPath -PathType Container) {
      $remainingCodexItems = @(Get-ChildItem -LiteralPath $codexDirPath -Force -ErrorAction SilentlyContinue)
      if ($remainingCodexItems.Count -eq 0) {
        Invoke-RollbackRemoval -RemovalRequests @(@{ Path = $codexDirPath; Reason = "Remove empty Codex runtime directory" }) -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior
      }
    }
  }

  if ($preserveMetadataDir) {
    if (-not [string]::IsNullOrWhiteSpace($backupSessionPath) -and (Test-Path -LiteralPath $backupSessionPath -PathType Any)) {
      Invoke-RollbackRemoval -RemovalRequests @(@{ Path = $backupSessionPath; Reason = "Remove current setup backup session" }) -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior
    }

    if (Test-Path -LiteralPath $context.ManifestPath -PathType Leaf) {
      Invoke-RollbackRemoval -RemovalRequests @(@{ Path = $context.ManifestPath; Reason = "Remove current rollback manifest" }) -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior
    }

    if (Test-Path -LiteralPath $context.MetadataDirPath -PathType Container) {
      $remainingMetadataItems = @(Get-ChildItem -LiteralPath $context.MetadataDirPath -Force -ErrorAction SilentlyContinue)
      if ($remainingMetadataItems.Count -eq 0) {
        Invoke-RollbackRemoval -RemovalRequests @(@{ Path = $context.MetadataDirPath; Reason = "Remove empty metadata directory" }) -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior
      }
    }
  } else {
    if (Test-Path -LiteralPath $context.MetadataDirPath -PathType Any) {
      Invoke-RollbackRemoval -RemovalRequests @(@{ Path = $context.MetadataDirPath; Reason = "Remove metadata directory created by setup" }) -Summary ([ref]$summary) -AllowPermanentDeleteFallback ([ref]$allowPermanentDeleteFallback) -DeleteBehavior $DeleteBehavior
    }
  }

  $summary.Warnings = $warnings.Count
  Write-Host ""
  Write-Host "Rollback completed successfully."
  Write-Host ("- Restored: {0}" -f $summary.Restored)
  Write-Host ("- Trashed: {0}" -f $summary.Trashed)
  Write-Host ("- PermanentlyDeleted: {0}" -f $summary.PermanentlyDeleted)
  Write-Host ("- Edited: {0}" -f $summary.Edited)
  foreach ($warning in $warnings) {
    Write-Info ("Rollback warning: {0}" -f $warning)
  }
}

function Initialize-BackupContext {
  param(
    [string]$RootPath,
    [string]$MetadataDirName
  )

  if ([string]::IsNullOrWhiteSpace($script:BackupSessionId)) {
    $script:BackupSessionId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID
  }

  $metaDir = Join-Path $RootPath $MetadataDirName
  $backupBaseDir = Join-Path $metaDir "backups"
  $runDir = Join-Path $backupBaseDir $script:BackupSessionId
  $null = Ensure-Directory -Path $metaDir
  $null = Ensure-Directory -Path $backupBaseDir
  $null = Ensure-Directory -Path $runDir

  $script:BackupRootPath = [IO.Path]::GetFullPath((Get-Item -LiteralPath $runDir -Force).FullName)
}

function Backup-PathIfExists {
  param(
    [string]$Path,
    [string]$RootPath,
    [string]$MetadataDirName
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Any)) {
    return $null
  }

  $fullPath = Resolve-FullPathSafe -Path $Path
  if ($script:BackupPathIndex.ContainsKey($fullPath)) {
    return $script:BackupPathIndex[$fullPath]
  }

  Initialize-BackupContext -RootPath $RootPath -MetadataDirName $MetadataDirName
  if (-not [string]::IsNullOrWhiteSpace($script:BackupRootPath)) {
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($fullPath.StartsWith($script:BackupRootPath, $comparison)) {
      return $null
    }
  }

  $relative = ""
  $isExternal = $false
  if (Test-PathUnderRoot -RootPath $RootPath -TargetPath $fullPath) {
    $relative = Convert-ToPortableRelativePath -Path (Get-RelativePathSafe -BasePath $RootPath -TargetPath $fullPath)
  } else {
    $relative = Convert-ToPortableRelativePath -Path (Join-Path "external" (Split-Path -Leaf $fullPath))
    $isExternal = $true
  }

  $relativeSafe = ($relative -replace '[<>:"|?*]', '_')
  $backupPath = Join-Path $script:BackupRootPath $relativeSafe
  $backupParent = Split-Path -Parent $backupPath
  if (-not [string]::IsNullOrWhiteSpace($backupParent)) {
    $null = Ensure-Directory -Path $backupParent
  }

  $item = Get-Item -LiteralPath $fullPath -Force
  if ($item.PSIsContainer) {
    Copy-Item -LiteralPath $fullPath -Destination $backupPath -Recurse -Force
  } else {
    Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
  }

  $record = [ordered]@{
    OriginalPath = $fullPath
    OriginalRelativePath = $relative
    BackupPath = $backupPath
    BackupRelativePath = $relativeSafe
    IsExternal = $isExternal
  }

  $script:BackupPathIndex[$fullPath] = $record
  Write-Info ("Backup created: {0}" -f $backupPath)
  return $record
}

function Set-VscodeChatGptSettings {
  param(
    [string]$RootPath,
    [bool]$RunCodexInWsl,
    [string]$MetadataDirName = ".vsc_launcher"
  )

  $vscodeDir = Join-Path $RootPath ".vscode"
  $settingsPath = Join-Path $vscodeDir "settings.json"
  $settingsExistedBeforeSetup = Test-Path -LiteralPath $settingsPath -PathType Leaf
  $vscodeDirCreated = Ensure-Directory -Path $vscodeDir
  if ($vscodeDirCreated) {
    Set-HiddenDotPath -Path $vscodeDir
  }

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

  Backup-PathIfExists -Path $settingsPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  $json = $obj | ConvertTo-Json -Depth 50
  $referenceText = if (Test-Path -LiteralPath $settingsPath -PathType Leaf) { Get-Content -LiteralPath $settingsPath -Raw } else { "" }
  Write-Utf8NoBomText -Path $settingsPath -Content $json -ReferenceText $referenceText
  $settingsManifest = New-ManagedPathRecord -Path $settingsPath -RootPath $RootPath -Kind "file" -ExistedBeforeSetup $settingsExistedBeforeSetup

  return @{
    Path = $settingsPath
    ExistedBeforeSetup = $settingsExistedBeforeSetup
    PreviousRunCodexInWsl = $previousRunCodexInWsl
    PreviousOpenOnStartup = $previousOpenOnStartup
    Manifest = if ($null -ne $settingsManifest) {
      Merge-Hashtable -Base $settingsManifest -Additional @{
        managedKeys = [ordered]@{
          "chatgpt.runCodexInWindowsSubsystemForLinux" = @{
            existedBeforeSetup = ($null -ne $previousRunCodexInWsl)
            appliedValue = $RunCodexInWsl
          }
          "chatgpt.openOnStartup" = @{
            existedBeforeSetup = ($null -ne $previousOpenOnStartup)
            appliedValue = $true
          }
        }
      }
    } else { $null }
  }
}

function Set-CodeWorkspaceChatGptSettings {
  param(
    [string]$WorkspacePath,
    [bool]$RunCodexInWsl,
    [string]$RootPath,
    [string]$MetadataDirName = ".vsc_launcher",
    [Nullable[bool]]$ExistedBeforeSetup = $null
  )

  if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Leaf)) {
    return @{
      Applied = $false
      Reason = "Workspace file not found."
      Manifest = $null
    }
  }

  $workspaceExistedBeforeSetup = if ($null -ne $ExistedBeforeSetup) {
    [bool]$ExistedBeforeSetup
  } else {
    Test-Path -LiteralPath $WorkspacePath -PathType Leaf
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

  Backup-PathIfExists -Path $WorkspacePath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  Write-Utf8NoBomText -Path $WorkspacePath -Content ($workspaceObject | ConvertTo-Json -Depth 50) -ReferenceText $raw
  $workspaceManifest = New-ManagedPathRecord -Path $WorkspacePath -RootPath $RootPath -Kind "file" -ExistedBeforeSetup $workspaceExistedBeforeSetup
  return @{
    Applied = $true
    Reason = ""
    Path = $WorkspacePath
    ExistedBeforeSetup = $workspaceExistedBeforeSetup
    PreviousRunCodexInWsl = $previousRunCodexInWsl
    PreviousOpenOnStartup = $previousOpenOnStartup
    Manifest = if ($null -ne $workspaceManifest) {
      Merge-Hashtable -Base $workspaceManifest -Additional @{
        managedKeys = [ordered]@{
          "chatgpt.runCodexInWindowsSubsystemForLinux" = @{
            existedBeforeSetup = ($null -ne $previousRunCodexInWsl)
            appliedValue = $RunCodexInWsl
          }
          "chatgpt.openOnStartup" = @{
            existedBeforeSetup = ($null -ne $previousOpenOnStartup)
            appliedValue = $true
          }
        }
      }
    } else { $null }
  }
}

function Update-GitIgnoreBlock {
  param(
    [string]$RootPath,
    [bool]$TrackSessionHistory,
    [string]$MetadataDirName,
    [string[]]$AdditionalGeneratedFiles = @()
  )

  $gitignorePath = Join-Path $RootPath ".gitignore"
  $startMarker = "# >>> codex-session-isolator >>>"
  $endMarker = "# <<< codex-session-isolator <<<"

  $gitignoreExistedBeforeSetup = Test-Path -LiteralPath $gitignorePath -PathType Leaf
  if (-not $gitignoreExistedBeforeSetup) {
    return @{
      Applied = $false
      ExistedBeforeSetup = $false
      Manifest = New-ManagedPathRecord -Path $gitignorePath -RootPath $RootPath -Kind "file" -ExistedBeforeSetup $false -ExistsAfterSetup $false
    }
  }

  $blockLines = @(
    $startMarker
    "# Managed by Codex Session Isolator launcher wizard."
    "vsc_launcher.*"
  )

  if ($AdditionalGeneratedFiles.Count -gt 0) {
    foreach ($file in $AdditionalGeneratedFiles) {
      if (-not [string]::IsNullOrWhiteSpace($file)) {
        $blockLines += $file
      }
    }
  }

  $blockLines += @(
    "$MetadataDirName/"
  )

  $blockLines += @(
    ".codex/*"
    "!.codex/config.toml"
  )

  if ($TrackSessionHistory) {
    $blockLines += @(
      "!.codex/sessions/"
      "!.codex/sessions/**"
      "!.codex/archived_sessions/"
      "!.codex/archived_sessions/**"
      "!.codex/memories/"
      "!.codex/memories/**"
      "!.codex/session_index.jsonl"
    )
  }

  $blockLines += $endMarker
  $current = Get-Content -LiteralPath $gitignorePath -Raw
  $lineEnding = Get-PreferredLineEnding -Text $current
  $newBlock = ($blockLines -join $lineEnding) + $lineEnding
  $pattern = "(?ms)^" + [regex]::Escape($startMarker) + ".*?^" + [regex]::Escape($endMarker) + "\s*"
  Backup-PathIfExists -Path $gitignorePath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null

  $applied = $false
  if ([string]::IsNullOrEmpty($current)) {
    Write-Utf8NoBomText -Path $gitignorePath -Content $newBlock -ReferenceText $current
    $applied = $true
  } elseif ($current -match $pattern) {
    $updated = [regex]::Replace($current, $pattern, $newBlock)
    Write-Utf8NoBomText -Path $gitignorePath -Content $updated -ReferenceText $current
    $applied = $true
  } else {
    if (-not $current.EndsWith("`n")) {
      $current += $lineEnding
    }
    $updated = $current + $lineEnding + $newBlock
    Write-Utf8NoBomText -Path $gitignorePath -Content $updated -ReferenceText $current
    $applied = $true
  }

  $gitignoreManifest = New-ManagedPathRecord -Path $gitignorePath -RootPath $RootPath -Kind "file" -ExistedBeforeSetup $gitignoreExistedBeforeSetup
  return @{
    Applied = $applied
    ExistedBeforeSetup = $gitignoreExistedBeforeSetup
    Manifest = if ($null -ne $gitignoreManifest) {
      Merge-Hashtable -Base $gitignoreManifest -Additional @{
        startMarker = $startMarker
        endMarker = $endMarker
        trackSessionHistory = $TrackSessionHistory
      }
    } else { $null }
  }
}

function Initialize-WizardLogging {
  param(
    [string]$RootPath,
    [string]$MetadataDirName
  )

  $metaDir = Join-Path $RootPath $MetadataDirName
  $logsDir = Join-Path $metaDir "logs"
  $metaDirCreated = Ensure-Directory -Path $metaDir
  if ($metaDirCreated) {
    Set-HiddenDotPath -Path $metaDir
  }
  $null = Ensure-Directory -Path $logsDir
  $script:WizardLogPath = Join-Path $logsDir ("wizard-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
  Set-Content -LiteralPath $script:WizardLogPath -Value ("{0} [INFO] [wizard] start" -f (Get-LogTimestamp))
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
    trackSessionHistory = $null
    windowsShortcutEnabled = $null
    windowsShortcutLocation = $null
    windowsShortcutCustomPath = $null
  }

  if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
    try {
      $obj = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json -ErrorAction Stop
      foreach ($key in @("useRemoteWsl", "codexRunInWsl", "trackSessionHistory", "windowsShortcutEnabled")) {
        if ($obj.PSObject.Properties.Name -contains $key) {
          $raw = $obj.$key
          if ($raw -is [bool]) {
            $values[$key] = $raw
          }
        }
      }
      if ($null -eq $values.trackSessionHistory -and $obj.PSObject.Properties.Name -contains "ignoreSessions") {
        $rawIgnore = $obj.ignoreSessions
        if ($rawIgnore -is [bool]) {
          $values.trackSessionHistory = (-not [bool]$rawIgnore)
        }
      }
      if ($obj.PSObject.Properties.Name -contains "windowsShortcutLocation") {
        $rawLocation = [string]$obj.windowsShortcutLocation
        if (-not [string]::IsNullOrWhiteSpace($rawLocation)) {
          $values.windowsShortcutLocation = $rawLocation
        }
      }
      if ($obj.PSObject.Properties.Name -contains "windowsShortcutCustomPath") {
        $rawCustomPath = [string]$obj.windowsShortcutCustomPath
        if (-not [string]::IsNullOrWhiteSpace($rawCustomPath)) {
          $values.windowsShortcutCustomPath = $rawCustomPath
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
    [string]$RootPath,
    [string]$MetadataDirName,
    [Nullable[bool]]$UseRemoteWsl = $null,
    [Nullable[bool]]$CodexRunInWsl = $null,
    [bool]$TrackSessionHistory,
    [Nullable[bool]]$WindowsShortcutEnabled = $null,
    [string]$WindowsShortcutLocation = "",
    [string]$WindowsShortcutCustomPath = ""
  )

  $parent = Split-Path -Parent $DefaultsPath
  $parentCreated = Ensure-Directory -Path $parent
  if ($parentCreated) {
    Set-HiddenDotPath -Path $parent
  }

  $payload = [ordered]@{
    useRemoteWsl = if ($null -ne $UseRemoteWsl) { [bool]$UseRemoteWsl } else { $null }
    codexRunInWsl = if ($null -ne $CodexRunInWsl) { [bool]$CodexRunInWsl } else { $null }
    trackSessionHistory = $TrackSessionHistory
    windowsShortcutEnabled = if ($null -ne $WindowsShortcutEnabled) { [bool]$WindowsShortcutEnabled } else { $null }
    windowsShortcutLocation = if ([string]::IsNullOrWhiteSpace($WindowsShortcutLocation)) { $null } else { $WindowsShortcutLocation }
    windowsShortcutCustomPath = if ([string]::IsNullOrWhiteSpace($WindowsShortcutCustomPath)) { $null } else { $WindowsShortcutCustomPath }
    updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  }

  Backup-PathIfExists -Path $DefaultsPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  Set-Content -LiteralPath $DefaultsPath -Value ($payload | ConvertTo-Json -Depth 10)
}

function Get-DefaultWorkspaceFileName {
  param([string]$RootPath)

  $baseName = Split-Path -Leaf $RootPath
  if ([string]::IsNullOrWhiteSpace($baseName)) {
    $baseName = "workspace"
  }

  $safeName = $baseName -replace '[<>:"/\\|?*]', "-"
  if ([string]::IsNullOrWhiteSpace($safeName)) {
    $safeName = "workspace"
  }

  return "$safeName.code-workspace"
}

function Get-WindowsWslShortcutFileName {
  param(
    [string]$LauncherBaseName,
    [string]$RootPath
  )

  $leaf = Split-Path -Leaf $RootPath
  if ([string]::IsNullOrWhiteSpace($leaf)) {
    $leaf = "Project"
  }

  $safeLeaf = $leaf -replace '[<>:"/\\|?*]', " "
  $safeLeaf = [regex]::Replace($safeLeaf, '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($safeLeaf)) {
    $safeLeaf = "Project"
  }

  return "Open $safeLeaf.lnk"
}

function Remove-LegacyGeneratedArtifacts {
  param(
    [string]$RootPath,
    [string]$LauncherBaseName,
    [string]$MetadataDirName,
    [string[]]$AdditionalFiles = @()
  )

  $legacyPaths = @(
    (Join-Path $RootPath "$LauncherBaseName.ps1"),
    (Join-Path $RootPath "$LauncherBaseName.config.json"),
    (Join-Path $RootPath "$LauncherBaseName`_wsl.lnk"),
    (Join-Path $RootPath "$LauncherBaseName`_windows_wsl_bridge.bat"),
    (Join-Path $RootPath ".vsc_launcher_logs")
  )

  foreach ($file in $AdditionalFiles) {
    if (-not [string]::IsNullOrWhiteSpace($file)) {
      $legacyPaths += (Join-Path $RootPath $file)
    }
  }

  $removedArtifacts = @()
  foreach ($path in $legacyPaths) {
    if (Test-Path -LiteralPath $path -PathType Any) {
      Backup-PathIfExists -Path $path -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
      $removedArtifacts += (New-ManagedPathRecord -Path $path -RootPath $RootPath -Kind "legacy-artifact" -ExistsAfterSetup $false)
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  return $removedArtifacts
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

  $metadataDirCreated = Ensure-Directory -Path $metadataDirPath
  if ($metadataDirCreated) {
    Set-HiddenDotPath -Path $metadataDirPath
  }

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

  Backup-PathIfExists -Path $configPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
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
    if ([string]::IsNullOrWhiteSpace($Distro) -or $distroInPath -ieq $Distro) {
      $rest = $Matches[2] -replace '\\', '/'
      return "/$rest"
    }
    throw "WSL path '$InputPath' belongs to distro '$distroInPath', but launcher is configured for distro '$Distro'."
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
  $wslArgs = @()
  if ([string]::IsNullOrWhiteSpace($Distro)) {
    $wslArgs = @("--", "wslpath", "-a", "-u", $normalized)
  } else {
    $wslArgs = @("-d", $Distro, "--", "wslpath", "-a", "-u", $normalized)
  }
  $convertedRaw = & wsl.exe @wslArgs 2>&1
  $converted = ($convertedRaw | Out-String).Trim()
  $distroLabel = if ([string]::IsNullOrWhiteSpace($Distro)) { "<default>" } else { $Distro }
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
    throw "Failed to convert path '$InputPath' to Linux path in distro '$distroLabel'. wslpath: $converted"
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

function Ensure-Directory {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return $false
  }

  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return $true
}

function Set-HiddenDotPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Any)) {
    return
  }

  $leaf = Split-Path -Leaf $Path
  if ([string]::IsNullOrWhiteSpace($leaf) -or -not $leaf.StartsWith(".")) {
    return
  }

  try {
    if ($env:OS -eq "Windows_NT") {
      $item = Get-Item -LiteralPath $Path -Force
      if (-not ($item.Attributes -band [IO.FileAttributes]::Hidden)) {
        $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
      }
      return
    }

    if ($Path -match '^/mnt/[a-zA-Z]/') {
      $wslpathCommand = Get-Command wslpath -ErrorAction SilentlyContinue
      $attribCommand = Get-Command attrib.exe -ErrorAction SilentlyContinue
      if ($null -ne $wslpathCommand -and $null -ne $attribCommand) {
        $windowsPath = (& $wslpathCommand.Source -w $Path 2>$null | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($windowsPath)) {
          & $attribCommand.Source +h $windowsPath 2>$null | Out-Null
        }
      }
    }
  } catch {
  }
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

  $codexHomeCreated = Ensure-Directory -Path $codexHome
  if ($codexHomeCreated) {
    Set-HiddenDotPath -Path $codexHome
  }
  Write-LauncherLog ("LaunchTarget={0}" -f $launchTarget)
  Write-LauncherLog ("CODEX_HOME={0}" -f $codexHome)

  $shouldUseIsolatedUserData = $forceIsolatedCodeProcess -and -not [bool]$config.useRemoteWsl
  $userDataDir = $null
  $remoteWslAgentDir = $null
  if ($shouldUseIsolatedUserData) {
    $userDataDir = Join-Path $PSScriptRoot "vscode-user-data"
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    Write-LauncherLog ("VSCodeUserDataDir={0}" -f $userDataDir)
  } elseif ($forceIsolatedCodeProcess -and [bool]$config.useRemoteWsl) {
    Write-LauncherLog "RemoteWSLNote=Skipping isolated VS Code user-data-dir in Remote WSL mode."
    $remoteWslAgentDir = Join-Path $PSScriptRoot "vscode-agent"
    New-Item -ItemType Directory -Force -Path $remoteWslAgentDir | Out-Null
    Write-LauncherLog ("RemoteWSLAgentDir={0}" -f $remoteWslAgentDir)
  }

  if ($DryRun) {
    Write-Host ("[dry-run] Launch target: {0}" -f $launchTarget)
    Write-Host ("[dry-run] CODEX_HOME: {0}" -f $codexHome)
    if ($shouldUseIsolatedUserData -and -not [string]::IsNullOrWhiteSpace($userDataDir)) {
      Write-Host ("[dry-run] VSCode user-data-dir: {0}" -f $userDataDir)
    } elseif (-not [string]::IsNullOrWhiteSpace($remoteWslAgentDir)) {
      Write-Host ("[dry-run] Remote WSL VS Code agent dir: {0}" -f $remoteWslAgentDir)
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
    $remoteWslAgentDirLinux = $null
    $agentDirB64 = ""
    if (-not [string]::IsNullOrWhiteSpace($remoteWslAgentDir)) {
      $remoteWslAgentDirLinux = Convert-WindowsPathToLinuxPath -InputPath $remoteWslAgentDir -Distro $config.wslDistro
      $agentDirB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteWslAgentDirLinux))
    }
    $bashScript = @"
set -euo pipefail
target_b64='$targetB64'
target=`$(printf '%s' "`$target_b64" | base64 -d)
agent_b64='$agentDirB64'
vscode_agent_folder=""
if [ -n "`$agent_b64" ]; then
  vscode_agent_folder=`$(printf '%s' "`$agent_b64" | base64 -d)
fi
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
if [ -n "`$vscode_agent_folder" ]; then
  mkdir -p "`$vscode_agent_folder"
  export VSCODE_AGENT_FOLDER="`$vscode_agent_folder"
fi
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
    if (-not [string]::IsNullOrWhiteSpace($remoteWslAgentDirLinux)) {
      Write-LauncherLog ("RemoteWSLAgentDirLinux={0}" -f $remoteWslAgentDirLinux)
    }
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

  Backup-PathIfExists -Path $runnerPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
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
  Backup-PathIfExists -Path $launcherPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  Set-Content -LiteralPath $launcherPath -Value $batContent

  return @{
    ConfigPath = $configPath
    LauncherPath = $launcherPath
    RunnerPath = $runnerPath
    MetadataPath = $metadataDirPath
  }
}

function New-WindowsWslShortcutForWindowsTarget {
  param(
    [string]$ShortcutPath,
    [string]$ProjectLauncherPath,
    [string]$IconLocation
  )

  $workingDirectory = Split-Path -Parent $ProjectLauncherPath
  New-WindowsShortcutFile `
    -ShortcutPath $ShortcutPath `
    -TargetPath $ProjectLauncherPath `
    -Arguments "" `
    -WorkingDirectory $workingDirectory `
    -Description "Open project in VS Code (WSL)" `
    -IconLocation $IconLocation
}

function New-WindowsWslShortcutForLinuxTarget {
  param(
    [string]$ShortcutPath,
    [string]$LinuxProjectRoot,
    [string]$WslDistro,
    [string]$LinuxUser,
    [string]$IconLocation
  )

  $normalizedDistro = Normalize-WslName -Name (($WslDistro -replace [string][char]0, "").Trim())
  $normalizedUser = (($LinuxUser -replace [string][char]0, "").Trim())
  $linuxLauncherPath = ($LinuxProjectRoot.TrimEnd("/") + "/vsc_launcher.sh")
  $wslExePath = Get-WindowsWslExecutablePath
  $cmdExePath = Get-WindowsCmdExecutablePath
  $windowsRoot = if ($env:OS -eq "Windows_NT") { $env:SystemRoot } else {
    try {
      ((& powershell.exe -NoProfile -Command '$env:SystemRoot' 2>$null) | Out-String).Trim()
    } catch {
      ""
    }
  }
  # cmd.exe does not support UNC working directories reliably; keep Start In on a local Windows path.
  $workingDirectory = if ([string]::IsNullOrWhiteSpace($windowsRoot)) { "" } else { $windowsRoot }

  $argumentParts = @()
  if (-not [string]::IsNullOrWhiteSpace($normalizedDistro)) {
    $argumentParts += "-d $normalizedDistro"
  }
  if (-not [string]::IsNullOrWhiteSpace($normalizedUser)) {
    $argumentParts += "-u $normalizedUser"
  }
  $escapedLauncherPath = Escape-BashSingleQuoted -Value $linuxLauncherPath
  $argumentParts += "-- bash -lc `"bash '" + $escapedLauncherPath + "'`""
  $wslArguments = ($argumentParts -join " ")
  $wslInvocation = "`"$wslExePath`" $wslArguments"
  # Route through cmd.exe because direct wsl.exe targets in .lnk can no-op on some Windows setups.
  $arguments = "/d /c `"$wslInvocation`""

  New-WindowsShortcutFile `
    -ShortcutPath $ShortcutPath `
    -TargetPath $cmdExePath `
    -Arguments $arguments `
    -WorkingDirectory $workingDirectory `
    -Description "Open project in VS Code (WSL)" `
    -IconLocation $IconLocation
}

function New-UnixLauncherFile {
  param(
    [string]$RootPath,
    [string]$LauncherBaseName,
    [string]$MetadataDirName,
    [string]$LaunchMode,
    [string]$WorkspaceRelativePath,
    [bool]$EnableLoggingByDefault,
    [string]$WslDistro = ""
  )

  $scriptPath = Join-Path $RootPath "$LauncherBaseName.sh"
  $metadataDirPath = Join-Path $RootPath $MetadataDirName
  $configPath = Join-Path $metadataDirPath "config.env"
  $null = Ensure-Directory -Path $metadataDirPath

  $workspaceRelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($WorkspaceRelativePath))
  $enableLoggingLiteral = if ($EnableLoggingByDefault) { "1" } else { "0" }
  $configContent = @"
LAUNCH_MODE='$LaunchMode'
WORKSPACE_REL_B64='$workspaceRelB64'
ENABLE_LOGGING='$enableLoggingLiteral'
"@
  $configContent = ($configContent -replace "`r`n", "`n") -replace "`r", "`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  Backup-PathIfExists -Path $configPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  [System.IO.File]::WriteAllText($configPath, $configContent, $utf8NoBom)

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

if command -v setsid >/dev/null 2>&1; then
  setsid -f code --new-window "$launch_target" >/dev/null 2>&1
elif command -v nohup >/dev/null 2>&1; then
  nohup code --new-window "$launch_target" >/dev/null 2>&1 &
else
  code --new-window "$launch_target" >/dev/null 2>&1 &
fi

sleep 1
'@

  $content = $template.Replace("__META_DIR__", $MetadataDirName)
  $content = ($content -replace "`r`n", "`n") -replace "`r", "`n"

  Backup-PathIfExists -Path $scriptPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  [System.IO.File]::WriteAllText($scriptPath, $content, $utf8NoBom)
  if (($env:OS -eq "Windows_NT") -and (Test-IsWslUncPath -Path $scriptPath)) {
    try {
      $linuxScriptPath = Convert-WindowsPathToLinuxPath -InputPath $scriptPath -Distro $WslDistro
      $escapedScriptPath = Escape-BashSingleQuoted -Value $linuxScriptPath
      $wslArgs = @()
      if ([string]::IsNullOrWhiteSpace($WslDistro)) {
        $wslArgs = @("--", "bash", "-lc", ("chmod +x '" + $escapedScriptPath + "'"))
      } else {
        $wslArgs = @("-d", $WslDistro, "--", "bash", "-lc", ("chmod +x '" + $escapedScriptPath + "'"))
      }
      $null = & wsl.exe @wslArgs 2>&1
    } catch {
    }
  } else {
    try {
      & chmod +x $scriptPath | Out-Null
    } catch {
    }
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
$launcherFileName = ""
$enableLoggingByDefault = [bool]$DebugMode
$wslAvailable = $platformIsWindows -and (Test-WslAvailable)
$deferredFallbackInfo = $null

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
  $TargetPath = Read-NonEmpty -Prompt "Enter target folder path (repo or code folder)"
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Any)) {
  if ($platformIsWindows -and -not $wslAvailable -and (Test-IsWslUncPath -Path $TargetPath)) {
    $fallbackTargetPath = (Get-Location).Path
    if (-not (Test-Path -LiteralPath $fallbackTargetPath -PathType Any)) {
      throw "Path not found: $TargetPath"
    }

    $deferredFallbackInfo = "WSL target path is unavailable on this host. Falling back to current directory: $fallbackTargetPath"
    $TargetPath = $fallbackTargetPath
  } else {
    throw "Path not found: $TargetPath"
  }
}

$resolvedTargetInfo = Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop | Select-Object -First 1
$resolvedTarget = [IO.Path]::GetFullPath($resolvedTargetInfo.ProviderPath)
$targetItem = Get-Item -LiteralPath $resolvedTarget -Force
$targetRoot = if ($targetItem.PSIsContainer) { $resolvedTarget } else { Split-Path -Parent $resolvedTarget }
$metadataDirExistedBeforeSetup = Test-Path -LiteralPath (Join-Path $targetRoot $metadataDirName) -PathType Container
$isWslUncProjectTarget = $platformIsWindows -and (Test-IsWslUncPath -Path $resolvedTarget)
$isWslLinuxProjectTarget = (Test-IsWslLinuxEnvironment) -and $resolvedTarget.StartsWith("/")
$isLinuxHostedProjectTarget = $isWslUncProjectTarget -or $isWslLinuxProjectTarget
$shouldGenerateWindowsWslShortcut = $isWslUncProjectTarget -or $isWslLinuxProjectTarget
$launcherFileName = if ($isLinuxHostedProjectTarget) { "$launcherBaseName.sh" } elseif ($platformIsWindows) { "$launcherBaseName.bat" } else { "$launcherBaseName.sh" }
$windowsWslShortcutFileName = if ($shouldGenerateWindowsWslShortcut) {
  Get-WindowsWslShortcutFileName -LauncherBaseName $launcherBaseName -RootPath $targetRoot
} else {
  ""
}
if ($Rollback) {
  if (Test-Path -LiteralPath (Join-Path $targetRoot $metadataDirName) -PathType Container) {
    Initialize-WizardLogging -RootPath $targetRoot -MetadataDirName $metadataDirName
  }

  if (-not [string]::IsNullOrWhiteSpace($deferredFallbackInfo)) {
    Write-Info $deferredFallbackInfo
  }

  Write-Info ("Rollback target root: {0}" -f $targetRoot)
  if ($RollbackRemoveCodexRuntimeData) {
    Write-Info "Rollback will also remove project Codex runtime data under .codex/ (except config.toml)."
  }
  Invoke-RollbackForTarget -RootPath $targetRoot -MetadataDirName $metadataDirName -RemoveCodexRuntimeData:$RollbackRemoveCodexRuntimeData -DeleteBehavior $RollbackDeleteBehavior
  exit 0
}

Initialize-WizardLogging -RootPath $targetRoot -MetadataDirName $metadataDirName
$defaultsInfo = Get-WizardDefaults -RootPath $targetRoot -MetadataDirName $metadataDirName
$wizardDefaults = $defaultsInfo.Values

if (-not [string]::IsNullOrWhiteSpace($deferredFallbackInfo)) {
  Write-Info $deferredFallbackInfo
}

Write-Info ("Target root: {0}" -f $targetRoot)
Write-Info ("Generated launcher file: {0}" -f $launcherFileName)
if ($shouldGenerateWindowsWslShortcut) {
  Write-Info "Target detected in WSL filesystem."
}
Write-Info ("Wizard log: {0}" -f $script:WizardLogPath)
if ($null -ne $wizardDefaults.useRemoteWsl -or $null -ne $wizardDefaults.codexRunInWsl -or $null -ne $wizardDefaults.trackSessionHistory -or $null -ne $wizardDefaults.windowsShortcutEnabled -or $null -ne $wizardDefaults.windowsShortcutLocation) {
  Write-Info ("Loaded defaults: remoteWsl={0}, codexInWsl={1}, trackSessionHistory={2}, windowsShortcutEnabled={3}, windowsShortcutLocation={4}" -f $wizardDefaults.useRemoteWsl, $wizardDefaults.codexRunInWsl, $wizardDefaults.trackSessionHistory, $wizardDefaults.windowsShortcutEnabled, $wizardDefaults.windowsShortcutLocation)
}

$launchMode = "folder"
$workspaceRelativePath = ""
$generatedWorkspacePath = ""
$generatedWorkspaceCreated = $false

if (-not $targetItem.PSIsContainer -and $targetItem.Extension -ieq ".code-workspace") {
  $launchMode = "workspace"
  $workspaceRelativePath = Get-RelativePathSafe -BasePath $targetRoot -TargetPath $resolvedTarget
  Write-Info ("Launch target defaulted to workspace: {0}" -f $workspaceRelativePath)
} else {
  $workspaceFiles = @(
    Get-ChildItem -Path $targetRoot -Filter *.code-workspace -File -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName }
  )

  if ($workspaceFiles.Count -eq 0) {
    $generatedWorkspaceFileName = Get-DefaultWorkspaceFileName -RootPath $targetRoot
    $generatedWorkspacePath = Join-Path $targetRoot $generatedWorkspaceFileName
    $workspacePayload = [ordered]@{
      folders = @(
        [ordered]@{ path = "." }
      )
    }

    Backup-PathIfExists -Path $generatedWorkspacePath -RootPath $targetRoot -MetadataDirName $metadataDirName | Out-Null
    Set-Content -LiteralPath $generatedWorkspacePath -Value ($workspacePayload | ConvertTo-Json -Depth 10)

    $generatedWorkspaceCreated = $true
    $launchMode = "workspace"
    $workspaceRelativePath = Get-RelativePathSafe -BasePath $targetRoot -TargetPath $generatedWorkspacePath
    Write-Info ("No workspace file found. Created workspace: {0}" -f $workspaceRelativePath)
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
[Nullable[bool]]$useRemoteWslForDefaults = $null
[Nullable[bool]]$codexRunInWslForDefaults = $null
[Nullable[bool]]$windowsShortcutEnabledForDefaults = $null
$windowsShortcutLocationForDefaults = ""
$windowsShortcutCustomPathForDefaults = ""
$createWindowsShortcut = $false
$windowsShortcutLocationKey = ""
$windowsShortcutCustomPath = ""
$windowsShortcutDestinationDir = ""
$windowsShortcutPathForGeneration = ""
$windowsShortcutPathForOutput = ""
$shortcutLivesInProjectRoot = $false
$windowsShortcutExistedBeforeSetup = $false

if ($platformIsWindows -and $wslAvailable) {
  $remoteDefault = $false
  if ($null -ne $wizardDefaults.useRemoteWsl) {
    $remoteDefault = [bool]$wizardDefaults.useRemoteWsl
    Write-Info "Remote WSL default loaded from saved wizard defaults."
  } elseif ($isWslUncProjectTarget) {
    $remoteDefault = $true
    Write-Info "Remote WSL default: enabled (WSL UNC path detected)."
  } else {
    $remoteDefault = $false
    Write-Info "Remote WSL default: disabled (local Windows path detected)."
  }
  $useRemoteWsl = Read-YesNo -Prompt "Launch VS Code in Remote WSL mode?" -DefaultValue $remoteDefault
  $useRemoteWslForDefaults = $useRemoteWsl
  Write-Info ("Remote WSL launch: {0}" -f ($(if ($useRemoteWsl) { "enabled" } else { "disabled" })))
  if ($useRemoteWsl) {
    $distros = @(Get-WslDistroList)
    Write-Info ("Detected WSL distros: {0}" -f (($distros | ForEach-Object { "'$_'" }) -join ", "))
    if ($distros.Count -eq 0) {
      throw "No WSL distro found. Install WSL or choose local mode."
    }

    $targetDistroHint = Get-WslDistroHintFromTargetPath -Path $TargetPath
    $targetDistroHintIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($targetDistroHint)) {
      for ($i = 0; $i -lt $distros.Count; $i++) {
        if ($distros[$i] -ieq $targetDistroHint) {
          $targetDistroHintIndex = $i
          break
        }
      }
    }

    if ($targetDistroHintIndex -ge 0) {
      $wslDistro = $distros[$targetDistroHintIndex]
      Write-Info ("Using WSL distro inferred from target path: {0}" -f $wslDistro)
    } elseif ($distros.Count -eq 1) {
      $wslDistro = $distros[0]
      Write-Info ("Using WSL distro (single detected): {0}" -f $wslDistro)
    } else {
      $defaultDistro = Get-DefaultWslDistro
      $defaultIndex = 0
      if (-not [string]::IsNullOrWhiteSpace($defaultDistro)) {
        for ($i = 0; $i -lt $distros.Count; $i++) {
          if ($distros[$i] -ieq $defaultDistro) {
            $defaultIndex = $i
            break
          }
        }
      }
      Write-Info ("WSL distro default selection: {0}" -f $distros[$defaultIndex])
      $idx = Read-ChoiceIndex -Title "Select WSL distro:" -Options $distros -DefaultIndex $defaultIndex
      $wslDistro = $distros[$idx]
      Write-Info ("Using WSL distro: {0}" -f $wslDistro)
    }
  }
} elseif ($platformIsWindows) {
  Write-Info "WSL not detected. WSL-related options are skipped."
}

$codexRunInWsl = if ($platformIsWindows -and $wslAvailable -and $useRemoteWsl) {
  $codexDefault = if ($null -ne $wizardDefaults.codexRunInWsl) { [bool]$wizardDefaults.codexRunInWsl } else { $true }
  Read-YesNo -Prompt "Set Codex to run in WSL for this project?" -DefaultValue $codexDefault
} else {
  $false
}
if ($platformIsWindows -and $wslAvailable -and $useRemoteWsl) {
  $codexRunInWslForDefaults = $codexRunInWsl
}
Write-Info ("VS Code setting chatgpt.runCodexInWindowsSubsystemForLinux = {0}" -f $codexRunInWsl.ToString().ToLowerInvariant())
Write-Info "VS Code setting chatgpt.openOnStartup = true"
if ($platformIsWindows -and $wslAvailable -and -not $useRemoteWsl) {
  Write-Info "Codex-in-WSL prompt skipped because Remote WSL launch is disabled."
}
if ($codexRunInWsl -and -not $useRemoteWsl) {
  Write-Info "Codex-in-WSL is enabled while VS Code launch mode is local Windows."
}

if ($shouldGenerateWindowsWslShortcut) {
  $createShortcutDefault = if ($null -ne $wizardDefaults.windowsShortcutEnabled) { [bool]$wizardDefaults.windowsShortcutEnabled } else { $false }
  $createWindowsShortcut = Read-YesNo -Prompt "Create Windows shortcut for double-click launch?" -DefaultValue $createShortcutDefault
  $windowsShortcutEnabledForDefaults = $createWindowsShortcut

  if ($createWindowsShortcut) {
    $locationOptions = @(
      "Project root",
      "Desktop",
      "Start Menu",
      "Custom path"
    )
    $locationKeyByIndex = @("projectRoot", "desktop", "startMenu", "custom")
    $defaultLocationIndex = 0
    if (-not [string]::IsNullOrWhiteSpace($wizardDefaults.windowsShortcutLocation)) {
      for ($i = 0; $i -lt $locationKeyByIndex.Count; $i++) {
        if ($locationKeyByIndex[$i] -eq $wizardDefaults.windowsShortcutLocation) {
          $defaultLocationIndex = $i
          break
        }
      }
    }

    $locationSelectionIndex = Read-ChoiceIndex -Title "Select Windows shortcut location:" -Options $locationOptions -DefaultIndex $defaultLocationIndex
    $windowsShortcutLocationKey = $locationKeyByIndex[$locationSelectionIndex]
    $windowsShortcutLocationForDefaults = $windowsShortcutLocationKey
    if ($windowsShortcutLocationKey -eq "custom") {
      $windowsShortcutCustomPath = Read-NonEmpty -Prompt "Enter Windows shortcut directory path" -DefaultValue ([string]$wizardDefaults.windowsShortcutCustomPath)
      $windowsShortcutCustomPathForDefaults = $windowsShortcutCustomPath
    } else {
      $windowsShortcutCustomPathForDefaults = ""
    }

    $windowsShortcutDestinationDir = Resolve-WindowsShortcutDirectoryPath `
      -LocationKey $windowsShortcutLocationKey `
      -TargetRoot $targetRoot `
      -CustomPath $windowsShortcutCustomPath
    if ([string]::IsNullOrWhiteSpace($windowsShortcutDestinationDir)) {
      $createWindowsShortcut = $false
      $windowsShortcutEnabledForDefaults = $false
      Write-Info ("Windows shortcut location '{0}' is unavailable. Shortcut generation skipped." -f $windowsShortcutLocationKey)
    } elseif (-not (Ensure-WindowsDirectoryPath -DirectoryPath $windowsShortcutDestinationDir)) {
      $createWindowsShortcut = $false
      $windowsShortcutEnabledForDefaults = $false
      Write-Info ("Unable to create/access Windows shortcut directory: {0}. Shortcut generation skipped." -f $windowsShortcutDestinationDir)
    } else {
      $windowsShortcutPathForGeneration = Join-WindowsPath -BasePath $windowsShortcutDestinationDir -Leaf $windowsWslShortcutFileName
      $windowsShortcutPathForOutput = $windowsShortcutPathForGeneration
      $shortcutLivesInProjectRoot = ($windowsShortcutLocationKey -eq "projectRoot")
      if ($shortcutLivesInProjectRoot) {
        $windowsShortcutPathForOutput = Join-Path $targetRoot $windowsWslShortcutFileName
      }
      Write-Info ("Windows shortcut location selected: {0}" -f $locationOptions[$locationSelectionIndex])
      Write-Info ("Windows shortcut destination: {0}" -f $windowsShortcutDestinationDir)
    }
  } else {
    Write-Info "Windows shortcut generation disabled."
  }
}

$trackHistoryDefault = if ($null -ne $wizardDefaults.trackSessionHistory) { [bool]$wizardDefaults.trackSessionHistory } else { $false }
$trackSessionHistory = Read-YesNo -Prompt "Track Codex session history in git?" -DefaultValue $trackHistoryDefault
Write-Info ("Codex session history git tracking: {0}" -f ($(if ($trackSessionHistory) { "enabled" } else { "disabled" })))
Write-Info ("Launcher logging default: {0}" -f ($(if ($enableLoggingByDefault) { "enabled (debug mode)" } else { "disabled" })))

$settingsWrite = Set-VscodeChatGptSettings -RootPath $targetRoot -RunCodexInWsl $codexRunInWsl -MetadataDirName $metadataDirName
if ($null -ne $settingsWrite.PreviousRunCodexInWsl -and $settingsWrite.PreviousRunCodexInWsl -ne $codexRunInWsl) {
  Write-Info "Codex WSL setting changed. If VS Code is already running, reload/restart may be required."
}

if ($launchMode -eq "workspace" -and -not [string]::IsNullOrWhiteSpace($workspaceRelativePath)) {
  $workspacePathForSettings = Join-Path $targetRoot $workspaceRelativePath
  $workspaceSettingsWrite = Set-CodeWorkspaceChatGptSettings `
    -WorkspacePath $workspacePathForSettings `
    -RunCodexInWsl $codexRunInWsl `
    -RootPath $targetRoot `
    -MetadataDirName $metadataDirName `
    -ExistedBeforeSetup (-not $generatedWorkspaceCreated)
  if ($workspaceSettingsWrite.Applied) {
    Write-Info ("Workspace settings updated in: {0}" -f $workspaceRelativePath)
    if ($null -ne $workspaceSettingsWrite.PreviousRunCodexInWsl -and $workspaceSettingsWrite.PreviousRunCodexInWsl -ne $codexRunInWsl) {
      Write-Info "Workspace Codex WSL setting changed."
    }
  } else {
    Write-Info ("Workspace settings were not updated: {0}" -f $workspaceSettingsWrite.Reason)
  }
}

Save-WizardDefaults `
  -DefaultsPath $defaultsInfo.Path `
  -RootPath $targetRoot `
  -MetadataDirName $metadataDirName `
  -UseRemoteWsl $useRemoteWslForDefaults `
  -CodexRunInWsl $codexRunInWslForDefaults `
  -TrackSessionHistory $trackSessionHistory `
  -WindowsShortcutEnabled $windowsShortcutEnabledForDefaults `
  -WindowsShortcutLocation $windowsShortcutLocationForDefaults `
  -WindowsShortcutCustomPath $windowsShortcutCustomPathForDefaults
$wizardDefaultsManifest = New-ManagedPathRecord -Path $defaultsInfo.Path -RootPath $targetRoot -Kind "file"
$legacyRemovedArtifacts = Remove-LegacyGeneratedArtifacts `
  -RootPath $targetRoot `
  -LauncherBaseName $launcherBaseName `
  -MetadataDirName $metadataDirName `
  -AdditionalFiles @($windowsWslShortcutFileName)

$additionalGeneratedFiles = @()
if ($createWindowsShortcut -and $shortcutLivesInProjectRoot) {
  $additionalGeneratedFiles += $windowsWslShortcutFileName
}

$gitignoreResult = Update-GitIgnoreBlock `
  -RootPath $targetRoot `
  -TrackSessionHistory $trackSessionHistory `
  -MetadataDirName $metadataDirName `
  -AdditionalGeneratedFiles $additionalGeneratedFiles
if ($gitignoreResult.Applied) {
  Write-Info "Managed .gitignore block updated."
} else {
  Write-Info "No .gitignore found in target root. Skipping .gitignore update."
}

$staleLauncherFileName = if ($launcherFileName.EndsWith(".sh")) { "$launcherBaseName.bat" } else { "$launcherBaseName.sh" }
$staleLauncherPath = Join-Path $targetRoot $staleLauncherFileName
$staleLauncherManifest = $null
if (Test-Path -LiteralPath $staleLauncherPath -PathType Leaf) {
  Backup-PathIfExists -Path $staleLauncherPath -RootPath $targetRoot -MetadataDirName $metadataDirName | Out-Null
  $staleLauncherManifest = New-ManagedPathRecord -Path $staleLauncherPath -RootPath $targetRoot -Kind "launcher" -ExistsAfterSetup $false
  Remove-Item -LiteralPath $staleLauncherPath -Force -ErrorAction SilentlyContinue
  Write-Info ("Removed stale launcher file: {0}" -f $staleLauncherFileName)
}

$outputs = if ($isLinuxHostedProjectTarget) {
  New-UnixLauncherFile `
    -RootPath $targetRoot `
    -LauncherBaseName $launcherBaseName `
    -MetadataDirName $metadataDirName `
    -LaunchMode $launchMode `
    -WorkspaceRelativePath $workspaceRelativePath `
    -EnableLoggingByDefault $enableLoggingByDefault `
    -WslDistro $wslDistro
} elseif ($platformIsWindows) {
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
    -EnableLoggingByDefault $enableLoggingByDefault `
    -WslDistro $wslDistro
}

$windowsShortcutIconLocation = if ($shouldGenerateWindowsWslShortcut) { Get-WindowsVsCodeIconLocation } else { "" }
$shortcutDistroForGeneration = if ($platformIsWindows) { $wslDistro } else { $env:WSL_DISTRO_NAME }
$shortcutLinuxUserForGeneration = if ($shouldGenerateWindowsWslShortcut) { Resolve-LinuxUserForWslShortcut -LinuxProjectRoot $targetRoot } else { "" }
if ($shouldGenerateWindowsWslShortcut -and -not [string]::IsNullOrWhiteSpace($shortcutLinuxUserForGeneration)) {
  Write-Info ("Windows shortcut Linux user: {0}" -f $shortcutLinuxUserForGeneration)
}

if ($createWindowsShortcut -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForGeneration)) {
  $windowsShortcutExistingPath = if ($shortcutLivesInProjectRoot -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForOutput)) {
    $windowsShortcutPathForOutput
  } else {
    $windowsShortcutPathForGeneration
  }
  if (-not [string]::IsNullOrWhiteSpace($windowsShortcutExistingPath)) {
    $windowsShortcutExistedBeforeSetup = Test-Path -LiteralPath $windowsShortcutExistingPath -PathType Any
    Backup-PathIfExists -Path $windowsShortcutExistingPath -RootPath $targetRoot -MetadataDirName $metadataDirName | Out-Null
  }

  if ($platformIsWindows) {
    $shortcutLinuxProjectRoot = if ($isWslUncProjectTarget) {
      Convert-WindowsPathToLinuxPath -InputPath $targetRoot -Distro $shortcutDistroForGeneration
    } else {
      $targetRoot
    }
    New-WindowsWslShortcutForLinuxTarget `
      -ShortcutPath $windowsShortcutPathForGeneration `
      -LinuxProjectRoot $shortcutLinuxProjectRoot `
      -WslDistro $shortcutDistroForGeneration `
      -LinuxUser $shortcutLinuxUserForGeneration `
      -IconLocation $windowsShortcutIconLocation
  } else {
    New-WindowsWslShortcutForLinuxTarget `
      -ShortcutPath $windowsShortcutPathForGeneration `
      -LinuxProjectRoot $targetRoot `
      -WslDistro $shortcutDistroForGeneration `
      -LinuxUser $shortcutLinuxUserForGeneration `
      -IconLocation $windowsShortcutIconLocation
  }

  if ($shortcutLivesInProjectRoot) {
    $outputs["WindowsWslShortcutPath"] = $windowsShortcutPathForOutput
  } else {
    $outputs["WindowsExternalShortcutPath"] = $windowsShortcutPathForGeneration
  }
}

if ($shouldGenerateWindowsWslShortcut -and $createWindowsShortcut -and [string]::IsNullOrWhiteSpace($windowsShortcutPathForGeneration)) {
  Write-Info "Windows WSL shortcut path was not resolved. Shortcut generation skipped."
}

if ($outputs.Contains("WindowsWslShortcutPath")) {
  Write-Info ("Windows WSL shortcut generated: {0}" -f $outputs["WindowsWslShortcutPath"])
}

if ($outputs.Contains("WindowsExternalShortcutPath")) {
  Write-Info ("Windows external shortcut generated: {0}" -f $outputs["WindowsExternalShortcutPath"])
}

if ($shouldGenerateWindowsWslShortcut -and $createWindowsShortcut -and [string]::IsNullOrWhiteSpace($windowsShortcutIconLocation)) {
  Write-Info "VS Code icon was not detected. Shortcut uses default system icon."
}

$rollbackMetadataDirPath = Join-Path $targetRoot $metadataDirName
$removedDuringSetup = @($legacyRemovedArtifacts)
if ($null -ne $staleLauncherManifest) {
  $removedDuringSetup += $staleLauncherManifest
}
$rollbackManifestData = [ordered]@{
  schemaVersion = 1
  targetRootPath = (Resolve-FullPathSafe -Path $targetRoot)
  metadataDirRelativePath = $metadataDirName
  launchMode = $launchMode
  workspaceRelativePath = if ([string]::IsNullOrWhiteSpace($workspaceRelativePath)) { $null } else { (Convert-ToPortableRelativePath -Path $workspaceRelativePath) }
  trackSessionHistory = $trackSessionHistory
  latestBackupSessionId = if ([string]::IsNullOrWhiteSpace($script:BackupSessionId)) { $null } else { $script:BackupSessionId }
  latestBackupProjectRelativePath = if ([string]::IsNullOrWhiteSpace($script:BackupSessionId)) { $null } else { (Convert-ToPortableRelativePath -Path (Join-Path $metadataDirName (Join-Path "backups" $script:BackupSessionId))) }
  updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  generatedWorkspace = if ($generatedWorkspaceCreated -and -not [string]::IsNullOrWhiteSpace($generatedWorkspacePath)) {
    $generatedWorkspaceRecord = New-ManagedPathRecord -Path $generatedWorkspacePath -RootPath $targetRoot -Kind "workspace-file"
    if ($null -ne $generatedWorkspaceRecord) {
      Merge-Hashtable -Base $generatedWorkspaceRecord -Additional @{
        createdByWizard = $true
      }
    } else { $null }
  } else { $null }
  managedFiles = [ordered]@{
    metadataDirectory = (New-ManagedPathRecord -Path $rollbackMetadataDirPath -RootPath $targetRoot -Kind "directory" -ExistedBeforeSetup $metadataDirExistedBeforeSetup)
    wizardDefaults = $wizardDefaultsManifest
    rollbackManifest = [ordered]@{
      kind = "file"
      pathScope = "project"
      projectRelativePath = (Convert-ToPortableRelativePath -Path (Join-Path $metadataDirName "rollback.manifest.json"))
      absolutePath = $null
    }
    vscodeSettings = $settingsWrite.Manifest
    workspaceSettings = if ($launchMode -eq "workspace") { $workspaceSettingsWrite.Manifest } else { $null }
    gitignore = $gitignoreResult.Manifest
    launcher = (New-ManagedPathRecord -Path $outputs["LauncherPath"] -RootPath $targetRoot -Kind "launcher")
    launcherConfig = (New-ManagedPathRecord -Path $outputs["ConfigPath"] -RootPath $targetRoot -Kind "launcher-config")
    launcherRunner = if ($outputs.Contains("RunnerPath")) { (New-ManagedPathRecord -Path $outputs["RunnerPath"] -RootPath $targetRoot -Kind "launcher-runner") } else { $null }
    windowsShortcut = if ($createWindowsShortcut -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForGeneration)) {
      $shortcutRecordPath = if ($shortcutLivesInProjectRoot -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForOutput)) {
        $windowsShortcutPathForOutput
      } else {
        $windowsShortcutPathForGeneration
      }
      $shortcutRecord = New-ManagedPathRecord -Path $shortcutRecordPath -RootPath $targetRoot -Kind "windows-shortcut" -ExistedBeforeSetup $windowsShortcutExistedBeforeSetup
      if ($null -ne $shortcutRecord) {
        Merge-Hashtable -Base $shortcutRecord -Additional @{
          enabled = $true
          locationKey = $windowsShortcutLocationKey
          livesInProjectRoot = $shortcutLivesInProjectRoot
        }
      } else { $null }
    } else { $null }
  }
  removedDuringSetup = @($removedDuringSetup | Where-Object { $null -ne $_ })
}
$rollbackManifestPath = Save-RollbackManifest -RootPath $targetRoot -MetadataDirName $metadataDirName -Manifest $rollbackManifestData
Write-Info ("Rollback manifest updated: {0}" -f $rollbackManifestPath)

Write-Host ""
Write-Host "Launcher generated successfully."
if ($script:BackupPathIndex.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($script:BackupRootPath)) {
  Write-Host ("- BackupPath: {0}" -f $script:BackupRootPath)
  Write-Host ("- BackedUpItems: {0}" -f $script:BackupPathIndex.Count)
}
foreach ($item in $outputs.GetEnumerator()) {
  Write-Host ("- {0}: {1}" -f $item.Key, $item.Value)
}
