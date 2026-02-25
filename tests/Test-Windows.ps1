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

  Write-Host "[test] Case 1: canonical launcher dry-run (folder + workspace)"
  $case1 = Join-Path $tmpRoot "case1-canonical"
  New-Item -ItemType Directory -Force -Path $case1 | Out-Null
  $ws1 = Join-Path $case1 "sample.code-workspace"
  Set-Content -LiteralPath $ws1 -Value "{}" -NoNewline

  $canonicalLauncher = Join-Path $repoRoot "launchers\CodexSessionIsolator.ps1"
  $outFolder = Invoke-ExternalPowerShellScript -ScriptPath $canonicalLauncher -Arguments @("-TargetPath", $case1, "-DryRun")
  Assert-True ($outFolder.ExitCode -eq 0) "Folder dry-run failed."
  Assert-Contains $outFolder.Output "[dry-run] Local CODEX_HOME: $case1\.codex" "Folder dry-run CODEX_HOME mismatch."

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
  $meta2 = Join-Path $case2 ".vsc_launcher"
  $runner2 = Join-Path $meta2 "runner.ps1"
  $config2 = Join-Path $meta2 "config.json"
  $defaults2 = Join-Path $meta2 "wizard.defaults.json"
  $vscodeSettings2 = Join-Path $case2 ".vscode\settings.json"
  $gitignore2 = Join-Path $case2 ".gitignore"

  Assert-True (Test-Path -LiteralPath $launcher2 -PathType Leaf) "Generated launcher not found."
  Assert-True (Test-Path -LiteralPath $runner2 -PathType Leaf) "Generated runner not found."
  Assert-True (Test-Path -LiteralPath $config2 -PathType Leaf) "Generated config not found."
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

  $gitignoreText2 = Get-Content -LiteralPath $gitignore2 -Raw
  Assert-Contains $gitignoreText2 "# >>> codex-session-isolator >>>" "Managed gitignore block start missing."
  Assert-Contains $gitignoreText2 ".vsc_launcher/" "Expected metadata folder ignore entry missing."

  $dryRun2 = Invoke-RunnerDryRun -RunnerPath $runner2
  Assert-True ($dryRun2.ExitCode -eq 0) "Runner dry-run failed in baseline case."
  Assert-Contains $dryRun2.Output "[dry-run] VSCode user-data-dir: $meta2\vscode-user-data" "Expected local user-data-dir in dry-run output."

  $run2 = Invoke-RunnerWithMockCode -RunnerPath $runner2
  Assert-True ($run2.ExitCode -eq 0) ("Runner execution failed in baseline case. Output: " + $run2.Output)
  Assert-Contains $run2.Output "mock-code --new-window --user-data-dir" "Expected local code launch command not observed."

  $latestLog2 = Get-LatestLog -LogsDir (Join-Path $meta2 "logs")
  $log2 = Get-Content -LiteralPath $latestLog2 -Raw
  Assert-Contains $log2 "Mode=Local" "Expected local launch mode in baseline log."
  Assert-Contains $log2 "CODEX_HOME=$case2\.codex" "Expected project CODEX_HOME in baseline log."

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
  $expectedWrapperLinux = Convert-WindowsPathToLinuxPath -InputPath $wrapper2
  Assert-True ($profile2Obj.'chatgpt.cliExecutable' -eq $expectedWrapperLinux) "chatgpt.cliExecutable mismatch for wrapper path."

  $wrapperText2 = Get-Content -LiteralPath $wrapper2 -Raw
  $expectedCodexHomeLinux2 = Convert-WindowsPathToLinuxPath -InputPath (Join-Path $case2 ".codex")
  Assert-Contains $wrapperText2 "export CODEX_HOME='$expectedCodexHomeLinux2'" "Wrapper does not force expected CODEX_HOME."

  $latestLog3 = Get-LatestLog -LogsDir (Join-Path $meta2 "logs")
  $log3 = Get-Content -LiteralPath $latestLog3 -Raw
  Assert-Contains $log3 "Configured chatgpt.cliExecutable=$expectedWrapperLinux" "Expected cliExecutable wiring log missing."

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

  Assert-Contains $logA "CODEX_HOME=$projectA\.codex" "Project A log has wrong CODEX_HOME."
  Assert-Contains $logB "CODEX_HOME=$projectB\.codex" "Project B log has wrong CODEX_HOME."

  $settingsAPath = Join-Path $projectA ".vsc_launcher\vscode-user-data\User\settings.json"
  $settingsBPath = Join-Path $projectB ".vsc_launcher\vscode-user-data\User\settings.json"
  $settingsA = Get-Content -LiteralPath $settingsAPath -Raw | ConvertFrom-Json
  $settingsB = Get-Content -LiteralPath $settingsBPath -Raw | ConvertFrom-Json

  Assert-True ($settingsA.'chatgpt.cliExecutable' -ne $settingsB.'chatgpt.cliExecutable') "Concurrent projects should not share chatgpt.cliExecutable path."
  Assert-Contains $settingsA.'chatgpt.cliExecutable' "/project-a/" "Project A cliExecutable path mismatch."
  Assert-Contains $settingsB.'chatgpt.cliExecutable' "/project-b/" "Project B cliExecutable path mismatch."

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

