param(
  [string]$TargetPath,
  [switch]$DebugMode
)

$ErrorActionPreference = "Stop"
$script:WizardLogPath = $null
$script:BackupSessionId = $null
$script:BackupRootPath = $null
$script:BackupPathIndex = @{}

function Write-Info {
  param([string]$Message)
  Write-Host ("[wizard] {0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message)
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

  $fullPath = [IO.Path]::GetFullPath((Get-Item -LiteralPath $Path -Force).FullName)
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
  try {
    $candidate = Get-RelativePathSafe -BasePath $RootPath -TargetPath $fullPath
    if ($candidate.StartsWith("..")) {
      $relative = Join-Path "external" (Split-Path -Leaf $fullPath)
    } else {
      $relative = $candidate
    }
  } catch {
    $relative = Join-Path "external" (Split-Path -Leaf $fullPath)
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

  $script:BackupPathIndex[$fullPath] = $backupPath
  Write-Info ("Backup created: {0}" -f $backupPath)
  return $backupPath
}

function Set-VscodeChatGptSettings {
  param(
    [string]$RootPath,
    [bool]$RunCodexInWsl,
    [string]$MetadataDirName = ".vsc_launcher"
  )

  $vscodeDir = Join-Path $RootPath ".vscode"
  $settingsPath = Join-Path $vscodeDir "settings.json"
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
  Set-Content -LiteralPath $settingsPath -Value $json

  return @{
    PreviousRunCodexInWsl = $previousRunCodexInWsl
    PreviousOpenOnStartup = $previousOpenOnStartup
  }
}

function Set-CodeWorkspaceChatGptSettings {
  param(
    [string]$WorkspacePath,
    [bool]$RunCodexInWsl,
    [string]$RootPath,
    [string]$MetadataDirName = ".vsc_launcher"
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

  Backup-PathIfExists -Path $WorkspacePath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
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
    [string]$MetadataDirName,
    [string[]]$AdditionalGeneratedFiles = @()
  )

  $gitignorePath = Join-Path $RootPath ".gitignore"
  $startMarker = "# >>> codex-session-isolator >>>"
  $endMarker = "# <<< codex-session-isolator <<<"

  if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
    return $false
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

  $current = Get-Content -LiteralPath $gitignorePath -Raw
  Backup-PathIfExists -Path $gitignorePath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null

  if ([string]::IsNullOrEmpty($current)) {
    Set-Content -LiteralPath $gitignorePath -Value $newBlock
    return $true
  }

  $pattern = "(?ms)^" + [regex]::Escape($startMarker) + ".*?^" + [regex]::Escape($endMarker) + "\s*"
  if ($current -match $pattern) {
    $updated = [regex]::Replace($current, $pattern, $newBlock)
    Set-Content -LiteralPath $gitignorePath -Value $updated
    return $true
  } else {
    if (-not $current.EndsWith("`n")) {
      $current += "`n"
    }
    $updated = $current + "`n" + $newBlock
    Set-Content -LiteralPath $gitignorePath -Value $updated
    return $true
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
    windowsShortcutEnabled = $null
    windowsShortcutLocation = $null
    windowsShortcutCustomPath = $null
  }

  if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
    try {
      $obj = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json -ErrorAction Stop
      foreach ($key in @("useRemoteWsl", "codexRunInWsl", "ignoreSessions", "windowsShortcutEnabled")) {
        if ($obj.PSObject.Properties.Name -contains $key) {
          $raw = $obj.$key
          if ($raw -is [bool]) {
            $values[$key] = $raw
          }
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
    [bool]$IgnoreSessions,
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
    ignoreSessions = $IgnoreSessions
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

  foreach ($path in $legacyPaths) {
    if (Test-Path -LiteralPath $path -PathType Any) {
      Backup-PathIfExists -Path $path -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
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
  $argumentParts += "-- $linuxLauncherPath"
  $wslArguments = ($argumentParts -join " ")
  $wslInvocation = "$wslExePath $wslArguments"
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
    [bool]$EnableLoggingByDefault
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

code --new-window "$launch_target"
'@

  $content = $template.Replace("__META_DIR__", $MetadataDirName)
  $content = ($content -replace "`r`n", "`n") -replace "`r", "`n"

  Backup-PathIfExists -Path $scriptPath -RootPath $RootPath -MetadataDirName $MetadataDirName | Out-Null
  [System.IO.File]::WriteAllText($scriptPath, $content, $utf8NoBom)
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
$isWslUncProjectTarget = $platformIsWindows -and (Test-IsWslUncPath -Path $resolvedTarget)
$isWslLinuxProjectTarget = (Test-IsWslLinuxEnvironment) -and $resolvedTarget.StartsWith("/")
$shouldGenerateWindowsWslShortcut = $isWslUncProjectTarget -or $isWslLinuxProjectTarget
$windowsWslShortcutFileName = if ($shouldGenerateWindowsWslShortcut) {
  Get-WindowsWslShortcutFileName -LauncherBaseName $launcherBaseName -RootPath $targetRoot
} else {
  ""
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
if ($null -ne $wizardDefaults.useRemoteWsl -or $null -ne $wizardDefaults.codexRunInWsl -or $null -ne $wizardDefaults.ignoreSessions -or $null -ne $wizardDefaults.windowsShortcutEnabled -or $null -ne $wizardDefaults.windowsShortcutLocation) {
  Write-Info ("Loaded defaults: remoteWsl={0}, codexInWsl={1}, ignoreSessions={2}, windowsShortcutEnabled={3}, windowsShortcutLocation={4}" -f $wizardDefaults.useRemoteWsl, $wizardDefaults.codexRunInWsl, $wizardDefaults.ignoreSessions, $wizardDefaults.windowsShortcutEnabled, $wizardDefaults.windowsShortcutLocation)
}

$launchMode = "folder"
$workspaceRelativePath = ""

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

$ignoreDefault = if ($null -ne $wizardDefaults.ignoreSessions) { [bool]$wizardDefaults.ignoreSessions } else { $false }
$ignoreSessions = Read-YesNo -Prompt "Ignore Codex chat sessions in gitignore?" -DefaultValue $ignoreDefault
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
    -MetadataDirName $metadataDirName
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
  -IgnoreSessions $ignoreSessions `
  -WindowsShortcutEnabled $windowsShortcutEnabledForDefaults `
  -WindowsShortcutLocation $windowsShortcutLocationForDefaults `
  -WindowsShortcutCustomPath $windowsShortcutCustomPathForDefaults
Remove-LegacyGeneratedArtifacts `
  -RootPath $targetRoot `
  -LauncherBaseName $launcherBaseName `
  -MetadataDirName $metadataDirName `
  -AdditionalFiles @($windowsWslShortcutFileName)

$additionalGeneratedFiles = @()
if ($createWindowsShortcut -and $shortcutLivesInProjectRoot) {
  $additionalGeneratedFiles += $windowsWslShortcutFileName
}

$gitignoreUpdated = Update-GitIgnoreBlock `
  -RootPath $targetRoot `
  -IgnoreSessions $ignoreSessions `
  -MetadataDirName $metadataDirName `
  -AdditionalGeneratedFiles $additionalGeneratedFiles
if ($gitignoreUpdated) {
  Write-Info "Managed .gitignore block updated."
} else {
  Write-Info "No .gitignore found in target root. Skipping .gitignore update."
}

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

$windowsShortcutIconLocation = if ($shouldGenerateWindowsWslShortcut) { Get-WindowsVsCodeIconLocation } else { "" }
$shortcutDistroForGeneration = if ($platformIsWindows) { $wslDistro } else { $env:WSL_DISTRO_NAME }
$shortcutLinuxUserForGeneration = if ($shouldGenerateWindowsWslShortcut) { Resolve-LinuxUserForWslShortcut -LinuxProjectRoot $targetRoot } else { "" }
if ($shouldGenerateWindowsWslShortcut -and -not [string]::IsNullOrWhiteSpace($shortcutLinuxUserForGeneration)) {
  Write-Info ("Windows shortcut Linux user: {0}" -f $shortcutLinuxUserForGeneration)
}

if ($createWindowsShortcut -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForGeneration)) {
  if ($shortcutLivesInProjectRoot -and -not [string]::IsNullOrWhiteSpace($windowsShortcutPathForOutput)) {
    Backup-PathIfExists -Path $windowsShortcutPathForOutput -RootPath $targetRoot -MetadataDirName $metadataDirName | Out-Null
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

Write-Host ""
Write-Host "Launcher generated successfully."
if ($script:BackupPathIndex.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($script:BackupRootPath)) {
  Write-Host ("- BackupPath: {0}" -f $script:BackupRootPath)
  Write-Host ("- BackedUpItems: {0}" -f $script:BackupPathIndex.Count)
}
foreach ($item in $outputs.GetEnumerator()) {
  Write-Host ("- {0}: {1}" -f $item.Key, $item.Value)
}
