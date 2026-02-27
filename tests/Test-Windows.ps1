Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Expected,
    [string]$Message
  )

  if (-not $Text.Contains($Expected)) {
    throw "Assertion failed: $Message`nExpected to contain: $Expected`nActual: $Text"
  }
}

function Assert-NotContains {
  param(
    [string]$Text,
    [string]$Unexpected,
    [string]$Message
  )

  if ($Text.Contains($Unexpected)) {
    throw "Assertion failed: $Message`nUnexpected content: $Unexpected`nActual: $Text"
  }
}

function Assert-HiddenOnWindows {
  param(
    [string]$Path,
    [string]$Message
  )

  Assert-True (Test-Path -LiteralPath $Path -PathType Any) ($Message + " (path not found: $Path)")
  $item = Get-Item -LiteralPath $Path -Force
  $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
  Assert-True $isHidden ($Message + " (attributes: " + $item.Attributes + ")")
}

function Convert-WindowsPathToLinuxPath {
  param([string]$InputPath)

  if ($InputPath -match '^[A-Za-z]:[\\/]') {
    $drive = $InputPath.Substring(0, 1).ToLowerInvariant()
    $rest = $InputPath.Substring(2) -replace '\\', '/'
    if (-not $rest.StartsWith('/')) {
      $rest = '/' + $rest
    }
    return "/mnt/$drive$rest"
  }

  return ($InputPath -replace '\\', '/')
}

function Test-HostWslAvailable {
  try {
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
      return $false
    }

    $null = cmd /c "wsl --status >nul 2>nul"
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Get-PrimaryWslDistro {
  try {
    return (
      wsl.exe -l -q 2>$null |
      ForEach-Object { ($_ -replace [string][char]0, "").Trim() } |
      Where-Object { $_ -and $_ -notmatch '^docker-desktop(-data)?$' } |
      Select-Object -First 1
    )
  } catch {
    return $null
  }
}

function Get-DefaultWslDistro {
  try {
    $status = (& wsl.exe --status 2>$null | Out-String)
    $normalized = $status -replace [string][char]0, ""
    $match = [regex]::Match($normalized, '(?im)Default\s*Distribution:\s*([^\r\n]+)')
    if ($match.Success) {
      return $match.Groups[1].Value.Trim()
    }
  } catch {
  }

  return $null
}

function Get-LatestLog {
  param(
    [string]$LogsDir,
    [string]$Pattern = "launcher-*.log"
  )

  $log = Get-ChildItem -LiteralPath $LogsDir -Filter $Pattern -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  Assert-True ($null -ne $log) "No log found in $LogsDir for pattern $Pattern"
  return $log.FullName
}

function Invoke-ExternalPowerShellScript {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments = @()
  )

  $outPath = Join-Path $env:TEMP ("csi-ps-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
  $errPath = Join-Path $env:TEMP ("csi-ps-err-" + [Guid]::NewGuid().ToString("N") + ".txt")
  try {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments
    $proc = Start-Process `
      -FilePath "powershell" `
      -ArgumentList $argList `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $outPath `
      -RedirectStandardError $errPath

    $stdout = if (Test-Path -LiteralPath $outPath -PathType Leaf) { Get-Content -LiteralPath $outPath -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $errPath -PathType Leaf) { Get-Content -LiteralPath $errPath -Raw } else { "" }
    $output = ($stdout + "`n" + $stderr).Trim()
    return @{
      ExitCode = $proc.ExitCode
      Output = $output
    }
  } finally {
    if (Test-Path -LiteralPath $outPath -PathType Leaf) {
      Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $errPath -PathType Leaf) {
      Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-Wizard {
  param(
    [string]$RepoRoot,
    [string]$TargetPath,
    [string[]]$Responses,
    [switch]$DebugMode,
    [switch]$UseTargetFlag
  )

  $inputFile = Join-Path $env:TEMP ("csi-wizard-input-" + [Guid]::NewGuid().ToString("N") + ".txt")
  try {
    $payload = if ($Responses.Count -gt 0) { ($Responses -join "`r`n") + "`r`n" } else { "" }
    Set-Content -LiteralPath $inputFile -Value $payload -NoNewline

    $debugArg = if ($DebugMode) { " --debug" } else { "" }
    $targetArg = if ($UseTargetFlag) { "--target ""$TargetPath""" } else { """$TargetPath""" }
    $cmd = "tools\vsc-launcher.bat $targetArg" + $debugArg + " < ""$inputFile"""
    Push-Location $RepoRoot
    try {
      cmd /c $cmd | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw "Wizard failed with exit code $LASTEXITCODE for target $TargetPath"
      }
    } finally {
      Pop-Location
    }
  } finally {
    if (Test-Path -LiteralPath $inputFile -PathType Leaf) {
      Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-WizardScriptDirect {
  param(
    [string]$RepoRoot,
    [string]$ScriptPath,
    [string]$TargetPath,
    [string[]]$Responses,
    [switch]$DebugMode
  )

  $inputFile = Join-Path $env:TEMP ("csi-wizard-input-" + [Guid]::NewGuid().ToString("N") + ".txt")
  try {
    $payload = if ($Responses.Count -gt 0) { ($Responses -join "`r`n") + "`r`n" } else { "" }
    Set-Content -LiteralPath $inputFile -Value $payload -NoNewline

    $debugArg = if ($DebugMode) { " -DebugMode" } else { "" }
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File ""$ScriptPath"" -TargetPath ""$TargetPath""" + $debugArg + " < ""$inputFile"""

    Push-Location $RepoRoot
    try {
      cmd /c $cmd | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw "Wizard script failed with exit code $LASTEXITCODE for target $TargetPath"
      }
    } finally {
      Pop-Location
    }
  } finally {
    if (Test-Path -LiteralPath $inputFile -PathType Leaf) {
      Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-RunnerDryRun {
  param([string]$RunnerPath)

  return Invoke-ExternalPowerShellScript -ScriptPath $RunnerPath -Arguments @("-DryRun")
}

function Invoke-RunnerWithMockCode {
  param([string]$RunnerPath)

  $escapedRunner = $RunnerPath.Replace("'", "''")
  $tempScript = Join-Path $env:TEMP ("csi-mock-runner-" + [Guid]::NewGuid().ToString("N") + ".ps1")
  $command = @"
function global:code {
  param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
  Start-Sleep -Milliseconds 200
  Write-Output ("mock-code " + (`$Args -join " "))
  `$global:LASTEXITCODE = 0
}
& '$escapedRunner' -Log
exit `$LASTEXITCODE
"@
  try {
    Set-Content -LiteralPath $tempScript -Value $command -NoNewline
    return Invoke-ExternalPowerShellScript -ScriptPath $tempScript
  } finally {
    if (Test-Path -LiteralPath $tempScript -PathType Leaf) {
      Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tmpRoot = Join-Path $env:TEMP ("csi-tests-" + [Guid]::NewGuid().ToString("N"))
$previousForceNoWsl = $env:CSI_FORCE_NO_WSL

New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
  $env:CSI_FORCE_NO_WSL = "1"

  Write-Host "[test] Case 0: wizard helper usage output"
  Push-Location $repoRoot
  try {
    $helpBat = cmd /c "tools\vsc-launcher.bat --help" 2>&1 | Out-String
    Assert-Contains $helpBat "Usage:" "Batch helper help output mismatch."

    $helpPs = Invoke-ExternalPowerShellScript -ScriptPath (Join-Path $repoRoot "tools\vsc-launcher.ps1") -Arguments @("--help")
    Assert-True ($helpPs.ExitCode -eq 0) "PowerShell helper help command failed."
    Assert-Contains $helpPs.Output "Usage:" "PowerShell helper help output mismatch."

    $missingTarget = Invoke-ExternalPowerShellScript -ScriptPath (Join-Path $repoRoot "tools\vsc-launcher.ps1") -Arguments @("--target")
    Assert-True ($missingTarget.ExitCode -ne 0) "PowerShell helper should fail when --target has no value."
    Assert-Contains $missingTarget.Output "Missing value for --target." "PowerShell helper missing-target error mismatch."
  } finally {
    Pop-Location
  }

  Write-Host "[test] Case 0.1: bundled wizard parity and hidden-dot paths"
  $toolWizardPath = Join-Path $repoRoot "tools\vsc-launcher-wizard.ps1"
  $bundledWizardPath = Join-Path $repoRoot "extension\scripts\vsc-launcher-wizard.ps1"
  $toolHash = (Get-FileHash -LiteralPath $toolWizardPath -Algorithm SHA256).Hash
  $bundledHash = (Get-FileHash -LiteralPath $bundledWizardPath -Algorithm SHA256).Hash
  Assert-True ($toolHash -eq $bundledHash) "Bundled wizard script is out of sync with tools wizard."

  $case01 = Join-Path $tmpRoot "case01-bundled-wizard"
  New-Item -ItemType Directory -Force -Path $case01 | Out-Null
  Set-Content -LiteralPath (Join-Path $case01 "bundled.code-workspace") -Value '{"folders":[{"path":"."}]}' -NoNewline
  Invoke-WizardScriptDirect -RepoRoot $repoRoot -ScriptPath $bundledWizardPath -TargetPath $case01 -Responses @("y")
  Assert-HiddenOnWindows -Path (Join-Path $case01 ".vsc_launcher") -Message "Expected .vsc_launcher to be hidden on Windows."
  Assert-HiddenOnWindows -Path (Join-Path $case01 ".vscode") -Message "Expected .vscode to be hidden on Windows."

  Write-Host "[test] Case 1: canonical launcher dry-run (folder + workspace)"
  $case1 = Join-Path $tmpRoot "case1-canonical"
  New-Item -ItemType Directory -Force -Path $case1 | Out-Null
  $ws1 = Join-Path $case1 "sample.code-workspace"
  Set-Content -LiteralPath $ws1 -Value "{}" -NoNewline

  $canonicalLauncher = Join-Path $repoRoot "launchers\CodexSessionIsolator.ps1"
  $outFolder = Invoke-ExternalPowerShellScript -ScriptPath $canonicalLauncher -Arguments @("-TargetPath", $case1, "-DryRun")
  Assert-True ($outFolder.ExitCode -eq 0) "Folder dry-run failed."
  Assert-Contains $outFolder.Output "[dry-run] Local launch target:" "Folder dry-run should report local launch target."
  Assert-Contains $outFolder.Output "\case1-canonical\sample.code-workspace" "Folder dry-run should prefer workspace launch target."
  Assert-Contains $outFolder.Output "[dry-run] Local CODEX_HOME:" "Folder dry-run should report local CODEX_HOME."
  Assert-Contains $outFolder.Output "\case1-canonical\.codex" "Folder dry-run CODEX_HOME mismatch."

  $outWorkspace = Invoke-ExternalPowerShellScript -ScriptPath $canonicalLauncher -Arguments @("-TargetPath", $ws1, "-DryRun")
  Assert-True ($outWorkspace.ExitCode -eq 0) "Workspace dry-run failed."
  Assert-Contains $outWorkspace.Output "[dry-run] Local CODEX_HOME: $case1\.codex" "Workspace dry-run CODEX_HOME mismatch."

  Write-Host "[test] Case 2: wizard generation baseline (WSL unavailable mode)"
  $case2 = Join-Path $tmpRoot "case2-wizard-local"
  New-Item -ItemType Directory -Force -Path $case2 | Out-Null
  $ws2 = Join-Path $case2 "app.code-workspace"
  Set-Content -LiteralPath $ws2 -Value '{"folders":[{"path":"."}]}' -NoNewline

  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case2 -Responses @("y") -DebugMode -UseTargetFlag

  $launcher2 = Join-Path $case2 "vsc_launcher.bat"
  $wslBridge2 = @(Get-ChildItem -LiteralPath $case2 -Filter "Open *.lnk" -File -ErrorAction SilentlyContinue)
  $meta2 = Join-Path $case2 ".vsc_launcher"
  $runner2 = Join-Path $meta2 "runner.ps1"
  $config2 = Join-Path $meta2 "config.json"
  $defaults2 = Join-Path $meta2 "wizard.defaults.json"
  $vscodeSettings2 = Join-Path $case2 ".vscode\settings.json"
  $gitignore2 = Join-Path $case2 ".gitignore"

  Assert-True (Test-Path -LiteralPath $launcher2 -PathType Leaf) "Generated launcher not found."
  Assert-True ($wslBridge2.Count -eq 0) "WSL shortcut should not be generated for local Windows targets."
  Assert-True (Test-Path -LiteralPath $runner2 -PathType Leaf) "Generated runner not found."
  Assert-True (Test-Path -LiteralPath $config2 -PathType Leaf) "Generated config not found."
  Assert-HiddenOnWindows -Path $meta2 -Message "Expected metadata directory to be hidden on Windows."
  Assert-HiddenOnWindows -Path (Join-Path $case2 ".vscode") -Message "Expected .vscode directory to be hidden on Windows."
  Assert-True (Test-Path -LiteralPath $defaults2 -PathType Leaf) "Wizard defaults file not found."
  Assert-True (Test-Path -LiteralPath $vscodeSettings2 -PathType Leaf) ".vscode/settings.json not found."
  Assert-True (Test-Path -LiteralPath $gitignore2 -PathType Leaf) ".gitignore not found."

  $config2Obj = Get-Content -LiteralPath $config2 -Raw | ConvertFrom-Json
  Assert-True (-not [bool]$config2Obj.useRemoteWsl) "Expected useRemoteWsl=false in baseline wizard config."
  Assert-True (-not [bool]$config2Obj.codexRunInWsl) "Expected codexRunInWsl=false when WSL is unavailable."
  Assert-True ([bool]$config2Obj.enableLoggingByDefault) "Expected enableLoggingByDefault=true in --debug mode."

  $vscode2Obj = Get-Content -LiteralPath $vscodeSettings2 -Raw | ConvertFrom-Json
  Assert-True ($vscode2Obj.'chatgpt.openOnStartup' -eq $true) "Expected chatgpt.openOnStartup=true in .vscode/settings.json."
  Assert-True ($vscode2Obj.'chatgpt.runCodexInWindowsSubsystemForLinux' -eq $false) "Expected runCodexInWsl=false in .vscode/settings.json."

  $workspace2Obj = Get-Content -LiteralPath $ws2 -Raw | ConvertFrom-Json
  Assert-True ($workspace2Obj.settings.'chatgpt.openOnStartup' -eq $true) "Expected chatgpt.openOnStartup=true in workspace settings."
  Assert-True ($workspace2Obj.settings.'chatgpt.runCodexInWindowsSubsystemForLinux' -eq $false) "Expected runCodexInWsl=false in workspace settings."

  Write-Host "[test] Case 2.0: WSL UNC target fallback when WSL is unavailable"
  $case20 = Join-Path $tmpRoot "case20-no-wsl-unc-fallback"
  New-Item -ItemType Directory -Force -Path $case20 | Out-Null
  $ws20 = Join-Path $case20 "fallback.code-workspace"
  Set-Content -LiteralPath $ws20 -Value '{"folders":[{"path":"."}]}' -NoNewline

  $case20InputFile = Join-Path $env:TEMP ("csi-wizard-input-" + [Guid]::NewGuid().ToString("N") + ".txt")
  $case20UncTarget = '\\wsl$\Ubuntu-NoWSL\home\user\project'
  try {
    Set-Content -LiteralPath $case20InputFile -Value "`r`n" -NoNewline
    $case20Cmd = ('pushd "{0}" && powershell -NoProfile -ExecutionPolicy Bypass -File "{1}" -TargetPath "{2}" < "{3}"' -f $case20, $toolWizardPath, $case20UncTarget, $case20InputFile)
    cmd /c $case20Cmd | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) "Case 2.0 wizard invocation failed for no-WSL UNC fallback."
  } finally {
    if (Test-Path -LiteralPath $case20InputFile -PathType Leaf) {
      Remove-Item -LiteralPath $case20InputFile -Force -ErrorAction SilentlyContinue
    }
  }

  $launcher20 = Join-Path $case20 "vsc_launcher.bat"
  $meta20 = Join-Path $case20 ".vsc_launcher"
  $runner20 = Join-Path $meta20 "runner.ps1"
  $config20 = Join-Path $meta20 "config.json"
  $vscodeSettings20 = Join-Path $case20 ".vscode\settings.json"

  Assert-True (Test-Path -LiteralPath $launcher20 -PathType Leaf) "Case 2.0 launcher was not generated in fallback root."
  Assert-True (Test-Path -LiteralPath $runner20 -PathType Leaf) "Case 2.0 runner was not generated in fallback root."
  Assert-True (Test-Path -LiteralPath $config20 -PathType Leaf) "Case 2.0 config was not generated in fallback root."
  Assert-True (Test-Path -LiteralPath $vscodeSettings20 -PathType Leaf) "Case 2.0 .vscode/settings.json was not generated in fallback root."

  $config20Obj = Get-Content -LiteralPath $config20 -Raw | ConvertFrom-Json
  Assert-True (-not [bool]$config20Obj.useRemoteWsl) "Case 2.0 should force local mode when WSL is unavailable."
  Assert-True (-not [bool]$config20Obj.codexRunInWsl) "Case 2.0 should force local Codex mode when WSL is unavailable."

  $vscode20Obj = Get-Content -LiteralPath $vscodeSettings20 -Raw | ConvertFrom-Json
  Assert-True ($vscode20Obj.'chatgpt.runCodexInWindowsSubsystemForLinux' -eq $false) "Case 2.0 should set runCodexInWsl=false in .vscode/settings.json."
  Assert-True ($vscode20Obj.'chatgpt.openOnStartup' -eq $true) "Case 2.0 should set chatgpt.openOnStartup=true in .vscode/settings.json."

  $workspace20Obj = Get-Content -LiteralPath $ws20 -Raw | ConvertFrom-Json
  Assert-True ($workspace20Obj.settings.'chatgpt.runCodexInWindowsSubsystemForLinux' -eq $false) "Case 2.0 should set runCodexInWsl=false in workspace settings."
  Assert-True ($workspace20Obj.settings.'chatgpt.openOnStartup' -eq $true) "Case 2.0 should set chatgpt.openOnStartup=true in workspace settings."

  $wizardLog20 = Get-LatestLog -LogsDir (Join-Path $meta20 "logs") -Pattern "wizard-*.log"
  $wizardLog20Text = Get-Content -LiteralPath $wizardLog20 -Raw
  Assert-Contains $wizardLog20Text "WSL target path is unavailable on this host. Falling back to current directory:" "Case 2.0 fallback note missing in wizard logs."

  $dryRun20 = Invoke-RunnerDryRun -RunnerPath $runner20
  Assert-True ($dryRun20.ExitCode -eq 0) "Case 2.0 runner dry-run failed."
  Assert-Contains $dryRun20.Output "[dry-run] VSCode user-data-dir:" "Case 2.0 should use local launcher mode after fallback."

  Write-Host "[test] Case 2.2: wizard auto-creates workspace when missing"
  $case22 = Join-Path $tmpRoot "case22-create-workspace"
  New-Item -ItemType Directory -Force -Path $case22 | Out-Null

  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case22 -Responses @("y") -DebugMode -UseTargetFlag

  $case22Name = Split-Path -Leaf $case22
  $case22Workspace = Join-Path $case22 ("{0}.code-workspace" -f $case22Name)
  $case22Config = Join-Path $case22 ".vsc_launcher\config.json"

  Assert-True (Test-Path -LiteralPath $case22Workspace -PathType Leaf) "Case 2.2 should auto-create workspace file."
  Assert-True (Test-Path -LiteralPath $case22Config -PathType Leaf) "Case 2.2 config file not found."

  $case22ConfigObj = Get-Content -LiteralPath $case22Config -Raw | ConvertFrom-Json
  Assert-True ($case22ConfigObj.launchMode -eq "workspace") "Case 2.2 launchMode should be workspace."
  Assert-True ($case22ConfigObj.workspaceRelativePath -eq ("{0}.code-workspace" -f $case22Name)) "Case 2.2 workspaceRelativePath mismatch."

  $case22WorkspaceObj = Get-Content -LiteralPath $case22Workspace -Raw | ConvertFrom-Json
  Assert-True ($case22WorkspaceObj.folders.Count -ge 1) "Case 2.2 workspace should include folders entry."
  Assert-True ($case22WorkspaceObj.folders[0].path -eq ".") "Case 2.2 workspace root folder should be '.'."
  Assert-True ($case22WorkspaceObj.settings.'chatgpt.openOnStartup' -eq $true) "Case 2.2 workspace should set chatgpt.openOnStartup=true."
  Assert-True ($case22WorkspaceObj.settings.'chatgpt.runCodexInWindowsSubsystemForLinux' -eq $false) "Case 2.2 workspace should set runCodexInWsl=false."

  $gitignoreText2 = Get-Content -LiteralPath $gitignore2 -Raw
  Assert-Contains $gitignoreText2 "# >>> codex-session-isolator >>>" "Managed gitignore block start missing."
  Assert-Contains $gitignoreText2 ".vsc_launcher/" "Expected metadata folder ignore entry missing."

  Write-Host "[test] Case 2.1: wizard creates safety backups before overwriting files"
  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case2 -Responses @("y") -DebugMode -UseTargetFlag
  $backupRoot2 = Join-Path $meta2 "backups"
  Assert-True (Test-Path -LiteralPath $backupRoot2 -PathType Container) "Backup root was not created."
  $latestBackup2 = Get-ChildItem -LiteralPath $backupRoot2 -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  Assert-True ($null -ne $latestBackup2) "No backup session folder found."
  Assert-True (Test-Path -LiteralPath (Join-Path $latestBackup2.FullName ".vscode\settings.json") -PathType Leaf) "Expected backup for .vscode/settings.json not found."
  Assert-True (Test-Path -LiteralPath (Join-Path $latestBackup2.FullName ".gitignore") -PathType Leaf) "Expected backup for .gitignore not found."

  $dryRun2 = Invoke-RunnerDryRun -RunnerPath $runner2
  Assert-True ($dryRun2.ExitCode -eq 0) "Runner dry-run failed in baseline case."
  Assert-Contains $dryRun2.Output "[dry-run] VSCode user-data-dir:" "Expected local user-data-dir label in dry-run output."
  Assert-Contains $dryRun2.Output ".vsc_launcher\vscode-user-data" "Expected local user-data-dir path segment in dry-run output."
  $codex2 = Join-Path $case2 ".codex"
  Assert-True (Test-Path -LiteralPath $codex2 -PathType Container) "Expected .codex directory to be created by runner."

  $run2 = Invoke-RunnerWithMockCode -RunnerPath $runner2
  Assert-True ($run2.ExitCode -eq 0) ("Runner execution failed in baseline case. Output: " + $run2.Output)
  Assert-Contains $run2.Output "mock-code --new-window --user-data-dir" "Expected local code launch command not observed."

  $latestLog2 = Get-LatestLog -LogsDir (Join-Path $meta2 "logs")
  $log2 = Get-Content -LiteralPath $latestLog2 -Raw
  Assert-Contains $log2 "Mode=Local" "Expected local launch mode in baseline log."
  Assert-Contains $log2 "CODEX_HOME=" "Expected CODEX_HOME entry in baseline log."
  Assert-Contains $log2 "case2-wizard-local\.codex" "Expected project CODEX_HOME path segment in baseline log."

  Write-Host "[test] Case 3: local Codex-in-WSL wrapper wiring"
  $config2Obj.codexRunInWsl = $true
  $config2Obj.useRemoteWsl = $false
  Set-Content -LiteralPath $config2 -Value ($config2Obj | ConvertTo-Json -Depth 20)

  $run3 = Invoke-RunnerWithMockCode -RunnerPath $runner2
  Assert-True ($run3.ExitCode -eq 0) ("Runner execution failed after enabling codexRunInWsl. Output: " + $run3.Output)

  $wrapper2 = Join-Path $meta2 "codex-wsl-wrapper.sh"
  $profileSettings2 = Join-Path $meta2 "vscode-user-data\User\settings.json"
  Assert-True (Test-Path -LiteralPath $wrapper2 -PathType Leaf) "Expected WSL wrapper file not generated."
  Assert-True (Test-Path -LiteralPath $profileSettings2 -PathType Leaf) "Expected isolated profile settings file not found."

  $profile2Obj = Get-Content -LiteralPath $profileSettings2 -Raw | ConvertFrom-Json
  $actualWrapperLinux = [string]$profile2Obj.'chatgpt.cliExecutable'
  Assert-True (-not [string]::IsNullOrWhiteSpace($actualWrapperLinux)) "chatgpt.cliExecutable should not be empty."
  Assert-Contains $actualWrapperLinux "codex-wsl-wrapper.sh" "chatgpt.cliExecutable should point to wrapper script."
  Assert-Contains $actualWrapperLinux "/case2-wizard-local/.vsc_launcher/" "chatgpt.cliExecutable should stay project-scoped."

  $wrapperText2 = Get-Content -LiteralPath $wrapper2 -Raw
  Assert-Contains $wrapperText2 "export CODEX_HOME='" "Wrapper should export CODEX_HOME."
  Assert-Contains $wrapperText2 "/case2-wizard-local/.codex'" "Wrapper should force project-scoped CODEX_HOME."

  $latestLog3 = Get-LatestLog -LogsDir (Join-Path $meta2 "logs")
  $log3 = Get-Content -LiteralPath $latestLog3 -Raw
  Assert-Contains $log3 "Configured chatgpt.cliExecutable=" "Expected cliExecutable wiring log missing."
  Assert-Contains $log3 "codex-wsl-wrapper.sh" "Expected wrapper path in cliExecutable wiring log."

  Write-Host "[test] Case 4: remote mode should skip isolated user-data-dir"
  $case4 = Join-Path $tmpRoot "case4-wizard-remote"
  New-Item -ItemType Directory -Force -Path $case4 | Out-Null
  $ws4 = Join-Path $case4 "remote.code-workspace"
  Set-Content -LiteralPath $ws4 -Value '{"folders":[{"path":"."}]}' -NoNewline

  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case4 -Responses @("y") -DebugMode
  $meta4 = Join-Path $case4 ".vsc_launcher"
  $runner4 = Join-Path $meta4 "runner.ps1"
  $config4 = Join-Path $meta4 "config.json"

  $config4Obj = Get-Content -LiteralPath $config4 -Raw | ConvertFrom-Json
  $config4Obj.useRemoteWsl = $true
  $config4Obj.wslDistro = "TestDistro"
  Set-Content -LiteralPath $config4 -Value ($config4Obj | ConvertTo-Json -Depth 20)

  $dryRun4 = Invoke-ExternalPowerShellScript -ScriptPath $runner4 -Arguments @("-DryRun", "-Log")
  Assert-True ($dryRun4.ExitCode -eq 0) "Remote-mode dry-run failed."
  Assert-NotContains $dryRun4.Output "VSCode user-data-dir" "Remote-mode dry-run should not print user-data-dir."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $meta4 "vscode-user-data") -PathType Any)) "Remote mode must not create vscode-user-data."

  $latestLog4 = Get-LatestLog -LogsDir (Join-Path $meta4 "logs")
  $log4 = Get-Content -LiteralPath $latestLog4 -Raw
  Assert-Contains $log4 "RemoteWSLNote=Skipping isolated VS Code user-data-dir in Remote WSL mode." "Remote mode note missing in logs."

  Write-Host "[test] Case 5: concurrent launcher runs isolate per-project state"
  $case5 = Join-Path $tmpRoot "case5-concurrency"
  $projectA = Join-Path $case5 "project-a"
  $projectB = Join-Path $case5 "project-b"
  New-Item -ItemType Directory -Force -Path $projectA | Out-Null
  New-Item -ItemType Directory -Force -Path $projectB | Out-Null
  Set-Content -LiteralPath (Join-Path $projectA "A.code-workspace") -Value '{"folders":[{"path":"."}]}' -NoNewline
  Set-Content -LiteralPath (Join-Path $projectB "B.code-workspace") -Value '{"folders":[{"path":"."}]}' -NoNewline

  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $projectA -Responses @("y") -DebugMode
  Invoke-Wizard -RepoRoot $repoRoot -TargetPath $projectB -Responses @("y") -DebugMode

  $configAPath = Join-Path $projectA ".vsc_launcher\config.json"
  $configBPath = Join-Path $projectB ".vsc_launcher\config.json"
  $configA = Get-Content -LiteralPath $configAPath -Raw | ConvertFrom-Json
  $configB = Get-Content -LiteralPath $configBPath -Raw | ConvertFrom-Json
  $configA.codexRunInWsl = $true
  $configB.codexRunInWsl = $true
  Set-Content -LiteralPath $configAPath -Value ($configA | ConvertTo-Json -Depth 20)
  Set-Content -LiteralPath $configBPath -Value ($configB | ConvertTo-Json -Depth 20)

  $runnerA = Join-Path $projectA ".vsc_launcher\runner.ps1"
  $runnerB = Join-Path $projectB ".vsc_launcher\runner.ps1"
  $jobScript = {
    param([string]$RunnerPath, [string]$Name)
    function global:code {
      param([Parameter(ValueFromRemainingArguments = $true)]$Args)
      Start-Sleep -Seconds 1
      Write-Output ("mock-" + $Name + " " + ($Args -join " "))
      $global:LASTEXITCODE = 0
    }
    try {
      & $RunnerPath -Log | Out-Null
      [PSCustomObject]@{
        Name = $Name
        ExitCode = $LASTEXITCODE
      }
    } finally {
      Remove-Item Function:\global:code -Force -ErrorAction SilentlyContinue
    }
  }

  $jobA = Start-Job -ScriptBlock $jobScript -ArgumentList $runnerA, "A"
  $jobB = Start-Job -ScriptBlock $jobScript -ArgumentList $runnerB, "B"
  Wait-Job -Job $jobA, $jobB | Out-Null
  $jobResults = Receive-Job -Job $jobA, $jobB
  Remove-Job -Job $jobA, $jobB

  foreach ($result in $jobResults) {
    Assert-True ($result.ExitCode -eq 0) "Concurrent runner '$($result.Name)' failed."
  }

  $logAPath = Get-LatestLog -LogsDir (Join-Path $projectA ".vsc_launcher\logs")
  $logBPath = Get-LatestLog -LogsDir (Join-Path $projectB ".vsc_launcher\logs")
  $logA = Get-Content -LiteralPath $logAPath -Raw
  $logB = Get-Content -LiteralPath $logBPath -Raw

  Assert-Contains $logA "CODEX_HOME=" "Project A log missing CODEX_HOME."
  Assert-Contains $logB "CODEX_HOME=" "Project B log missing CODEX_HOME."
  Assert-Contains $logA "project-a\.codex" "Project A log has wrong CODEX_HOME path segment."
  Assert-Contains $logB "project-b\.codex" "Project B log has wrong CODEX_HOME path segment."

  $settingsAPath = Join-Path $projectA ".vsc_launcher\vscode-user-data\User\settings.json"
  $settingsBPath = Join-Path $projectB ".vsc_launcher\vscode-user-data\User\settings.json"
  $settingsA = Get-Content -LiteralPath $settingsAPath -Raw | ConvertFrom-Json
  $settingsB = Get-Content -LiteralPath $settingsBPath -Raw | ConvertFrom-Json

  Assert-True ($settingsA.'chatgpt.cliExecutable' -ne $settingsB.'chatgpt.cliExecutable') "Concurrent projects should not share chatgpt.cliExecutable path."
  Assert-Contains $settingsA.'chatgpt.cliExecutable' "/project-a/" "Project A cliExecutable path mismatch."
  Assert-Contains $settingsB.'chatgpt.cliExecutable' "/project-b/" "Project B cliExecutable path mismatch."

  Write-Host "[test] Case 6: wizard target in WSL UNC path (mode matrix)"
  if (-not (Test-HostWslAvailable)) {
    Write-Host "[test] Case 6 skipped: WSL is not available on this host."
  } else {
    $case6Distro = Get-DefaultWslDistro
    if ([string]::IsNullOrWhiteSpace($case6Distro)) {
      $case6Distro = Get-PrimaryWslDistro
    }
    if ([string]::IsNullOrWhiteSpace($case6Distro)) {
      Write-Host "[test] Case 6 skipped: no non-docker WSL distro found."
    } else {
      $case6LinuxRoot = "/tmp/csi-windows-tests-wsl-" + [Guid]::NewGuid().ToString("N")
      $case6UncRoot = "\\wsl$\$case6Distro" + ($case6LinuxRoot -replace "/", "\")
      $case6WorkspacePath = Join-Path $case6UncRoot "sample.code-workspace"
      $case6ForceNoWsl = $env:CSI_FORCE_NO_WSL

      try {
        & wsl.exe -d $case6Distro -- mkdir -p $case6LinuxRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $case6UncRoot | Out-Null
        Set-Content -LiteralPath $case6WorkspacePath -Value '{"folders":[{"path":"."}]}' -NoNewline

        Remove-Item Env:CSI_FORCE_NO_WSL -ErrorAction SilentlyContinue
        $case6Distros = @(
          wsl.exe -l -q 2>$null |
          ForEach-Object { ($_ -replace [string][char]0, "").Trim() } |
          Where-Object { $_ -and $_ -notmatch '^docker-desktop(-data)?$' }
        )
        $case6Responses = if ($case6Distros.Count -gt 1) {
          # remoteWsl, distroSelection, codexRunInWsl, createShortcut, locationSelection, ignoreSessions
          @("", "", "", "y", "", "")
        } else {
          # remoteWsl, codexRunInWsl, createShortcut, locationSelection, ignoreSessions
          @("", "", "y", "", "")
        }
        Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case6UncRoot -Responses $case6Responses -DebugMode -UseTargetFlag

        $case6Runner = Join-Path $case6UncRoot ".vsc_launcher\runner.ps1"
        $case6Config = Join-Path $case6UncRoot ".vsc_launcher\config.json"
        $case6BridgeCandidates = @(Get-ChildItem -LiteralPath $case6UncRoot -Filter "Open *.lnk" -File -ErrorAction SilentlyContinue)
        $case6Wrapper = Join-Path $case6UncRoot ".vsc_launcher\codex-wsl-wrapper.sh"
        $case6ProfileSettings = Join-Path $case6UncRoot ".vsc_launcher\vscode-user-data\User\settings.json"
        $case6LogsDir = Join-Path $case6UncRoot ".vsc_launcher\logs"
        $case6Gitignore = Join-Path $case6UncRoot ".gitignore"

        Assert-True (Test-Path -LiteralPath $case6Runner -PathType Leaf) "Case 6 runner not generated."
        Assert-True (Test-Path -LiteralPath $case6Config -PathType Leaf) "Case 6 config not generated."
        Assert-True ($case6BridgeCandidates.Count -eq 1) "Case 6 Windows WSL shortcut not generated."
        Assert-True (Test-Path -LiteralPath $case6Gitignore -PathType Leaf) "Case 6 .gitignore not generated."

        $case6ConfigDefaults = Get-Content -LiteralPath $case6Config -Raw | ConvertFrom-Json
        Assert-True ([bool]$case6ConfigDefaults.useRemoteWsl) "Case 6 default should enable Remote WSL."
        Assert-True ([bool]$case6ConfigDefaults.codexRunInWsl) "Case 6 default should enable Codex-in-WSL."
        Assert-True ($case6ConfigDefaults.wslDistro -eq $case6Distro) "Case 6 default distro should match Windows default distro."

        $case6GitignoreText = Get-Content -LiteralPath $case6Gitignore -Raw
        Assert-Contains $case6GitignoreText $case6BridgeCandidates[0].Name "Case 6 gitignore missing Windows WSL shortcut entry."
        Assert-Contains $case6GitignoreText ".codex/*" "Case 6 default should keep sessions tracked (.codex/* strategy)."
        Assert-Contains $case6GitignoreText "!.codex/sessions/**" "Case 6 default should keep sessions unignored."
        Assert-Contains $case6GitignoreText "!.codex/archived_sessions/**" "Case 6 default should keep archived sessions unignored."

        Write-Host "[test] Case 6.1: local Windows path defaults to local mode"
        $case61 = Join-Path $tmpRoot "case61-local-defaults"
        New-Item -ItemType Directory -Force -Path $case61 | Out-Null
        Set-Content -LiteralPath (Join-Path $case61 "local.code-workspace") -Value '{"folders":[{"path":"."}]}' -NoNewline

        Invoke-Wizard -RepoRoot $repoRoot -TargetPath $case61 -Responses @("", "") -DebugMode -UseTargetFlag

        $case61ConfigPath = Join-Path $case61 ".vsc_launcher\config.json"
        Assert-True (Test-Path -LiteralPath $case61ConfigPath -PathType Leaf) "Case 6.1 config not generated."

        $case61Config = Get-Content -LiteralPath $case61ConfigPath -Raw | ConvertFrom-Json
        Assert-True (-not [bool]$case61Config.useRemoteWsl) "Case 6.1 default should disable Remote WSL for local Windows path."
        Assert-True (-not [bool]$case61Config.codexRunInWsl) "Case 6.1 should skip/disable Codex-in-WSL when Remote WSL is disabled."

        $case61WizardLogPath = Get-LatestLog -LogsDir (Join-Path $case61 ".vsc_launcher\logs") -Pattern "wizard-*.log"
        $case61WizardLog = Get-Content -LiteralPath $case61WizardLogPath -Raw
        Assert-Contains $case61WizardLog "local Windows path detected" "Case 6.1 wizard log should explain local Windows default."
        Assert-Contains $case61WizardLog "Codex-in-WSL prompt skipped because Remote WSL launch is disabled." "Case 6.1 should skip Codex-in-WSL prompt."

        function Set-Case6Config {
          param(
            [bool]$UseRemoteWsl,
            [bool]$CodexRunInWsl
          )

          $cfg = Get-Content -LiteralPath $case6Config -Raw | ConvertFrom-Json
          $cfg.useRemoteWsl = $UseRemoteWsl
          $cfg.codexRunInWsl = $CodexRunInWsl
          $cfg.wslDistro = if ($UseRemoteWsl) { $case6Distro } else { "" }
          Set-Content -LiteralPath $case6Config -Value ($cfg | ConvertTo-Json -Depth 20)
        }

        function Assert-Case6RemoteResult {
          param(
            $Result,
            [string]$Label
          )

          if ($Result.ExitCode -eq 0) {
            return
          }

          $known = @(
            "VS Code command 'code' not found in WSL PATH.",
            "Failed to launch VS Code in WSL mode."
          )
          foreach ($pattern in $known) {
            if ($Result.Output.Contains($pattern)) {
              return
            }
          }

          throw "Assertion failed: $Label`nUnexpected remote output: $($Result.Output)"
        }

        # Matrix A: VS Code local Windows, Codex local (Run in WSL = false)
        Set-Case6Config -UseRemoteWsl $false -CodexRunInWsl $false
        $case6LocalNoWsl = Invoke-RunnerWithMockCode -RunnerPath $case6Runner
        Assert-True ($case6LocalNoWsl.ExitCode -eq 0) ("Case 6A local/no-WSL failed. Output: " + $case6LocalNoWsl.Output)
        Assert-Contains $case6LocalNoWsl.Output "mock-code --new-window --user-data-dir" "Case 6A should use isolated user-data-dir launch."
        Assert-True (Test-Path -LiteralPath $case6ProfileSettings -PathType Leaf) "Case 6A isolated profile settings not generated."
        $case6ProfileNoWsl = Get-Content -LiteralPath $case6ProfileSettings -Raw | ConvertFrom-Json
        $case6ProfileNoWslPropNames = @($case6ProfileNoWsl.PSObject.Properties | ForEach-Object { $_.Name })
        if ($case6ProfileNoWslPropNames -contains "chatgpt.cliExecutable") {
          $case6CliNoWsl = [string]$case6ProfileNoWsl.'chatgpt.cliExecutable'
          Assert-True ([string]::IsNullOrWhiteSpace($case6CliNoWsl) -or -not $case6CliNoWsl.Contains("codex-wsl-wrapper.sh")) "Case 6A should not keep WSL wrapper override."
        }
        $case6LogAPath = Get-LatestLog -LogsDir $case6LogsDir
        $case6LogA = Get-Content -LiteralPath $case6LogAPath -Raw
        Assert-Contains $case6LogA "Mode=Local" "Case 6A log should show local mode."
        Assert-NotContains $case6LogA "Configured chatgpt.cliExecutable=" "Case 6A should not configure cliExecutable wrapper."

        # Matrix B: VS Code local Windows, Codex in WSL (Run in WSL = true)
        Set-Case6Config -UseRemoteWsl $false -CodexRunInWsl $true
        $case6LocalWithWsl = Invoke-RunnerWithMockCode -RunnerPath $case6Runner
        Assert-True ($case6LocalWithWsl.ExitCode -eq 0) ("Case 6B local/WSL failed. Output: " + $case6LocalWithWsl.Output)
        Assert-Contains $case6LocalWithWsl.Output "mock-code --new-window --user-data-dir" "Case 6B should use isolated user-data-dir launch."
        Assert-True (Test-Path -LiteralPath $case6Wrapper -PathType Leaf) "Case 6B wrapper file not generated."
        $case6ProfileWithWsl = Get-Content -LiteralPath $case6ProfileSettings -Raw | ConvertFrom-Json
        $case6CliWithWsl = [string]$case6ProfileWithWsl.'chatgpt.cliExecutable'
        Assert-Contains $case6CliWithWsl "/tmp/csi-windows-tests-wsl-" "Case 6B cliExecutable should map to WSL Linux path."
        Assert-Contains $case6CliWithWsl "/.vsc_launcher/codex-wsl-wrapper.sh" "Case 6B cliExecutable should point to wrapper script."
        $case6LogBPath = Get-LatestLog -LogsDir $case6LogsDir
        $case6LogB = Get-Content -LiteralPath $case6LogBPath -Raw
        Assert-Contains $case6LogB "Configured chatgpt.cliExecutable=" "Case 6B should configure cliExecutable wrapper."
        Assert-Contains $case6LogB "CODEX_HOME=" "Case 6B log should include CODEX_HOME entry."

        # Matrix C: VS Code in Remote WSL, Codex local flag (Run in WSL = false)
        Set-Case6Config -UseRemoteWsl $true -CodexRunInWsl $false
        $case6RemoteNoWsl = Invoke-ExternalPowerShellScript -ScriptPath $case6Runner -Arguments @("-Log")
        Assert-Case6RemoteResult -Result $case6RemoteNoWsl -Label "Case 6C remote/no-WSL"
        $case6LogCPath = Get-LatestLog -LogsDir $case6LogsDir
        $case6LogC = Get-Content -LiteralPath $case6LogCPath -Raw
        Assert-Contains $case6LogC ("Mode=RemoteWSL Distro={0}" -f $case6Distro) "Case 6C log should show remote WSL mode."
        Assert-Contains $case6LogC "WSLTarget=/tmp/csi-windows-tests-wsl-" "Case 6C should log Linux target path."
        Assert-Contains $case6LogC "RemoteWSLNote=Skipping isolated VS Code user-data-dir in Remote WSL mode." "Case 6C should skip isolated user-data-dir in remote mode."

        # Matrix D: VS Code in Remote WSL, Codex in WSL flag (Run in WSL = true)
        Set-Case6Config -UseRemoteWsl $true -CodexRunInWsl $true
        $case6RemoteWithWsl = Invoke-ExternalPowerShellScript -ScriptPath $case6Runner -Arguments @("-Log")
        Assert-Case6RemoteResult -Result $case6RemoteWithWsl -Label "Case 6D remote/WSL"
        $case6LogDPath = Get-LatestLog -LogsDir $case6LogsDir
        $case6LogD = Get-Content -LiteralPath $case6LogDPath -Raw
        Assert-Contains $case6LogD ("Mode=RemoteWSL Distro={0}" -f $case6Distro) "Case 6D log should show remote WSL mode."
        Assert-Contains $case6LogD "WSLTarget=/tmp/csi-windows-tests-wsl-" "Case 6D should log Linux target path."
      } finally {
        if ([string]::IsNullOrWhiteSpace($case6ForceNoWsl)) {
          Remove-Item Env:CSI_FORCE_NO_WSL -ErrorAction SilentlyContinue
        } else {
          $env:CSI_FORCE_NO_WSL = $case6ForceNoWsl
        }

        & wsl.exe -d $case6Distro -- rm -rf $case6LinuxRoot 2>$null | Out-Null
      }
    }
  }

  Write-Host "[test] All Windows tests passed."
} finally {
  if ([string]::IsNullOrWhiteSpace($previousForceNoWsl)) {
    Remove-Item Env:CSI_FORCE_NO_WSL -ErrorAction SilentlyContinue
  } else {
    $env:CSI_FORCE_NO_WSL = $previousForceNoWsl
  }

  if (Test-Path -LiteralPath $tmpRoot -PathType Any) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

