param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

function Show-Usage {
  Write-Host "Usage:"
  Write-Host "  vsc-launcher [<target-path>] [--debug] [--help]"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  vsc-launcher ""C:\dev\my-app"""
  Write-Host "  vsc-launcher ""/home/mehdi/projects/my-app"" --debug"
}

$targetPath = $null
$debugMode = $false

for ($i = 0; $i -lt $Arguments.Count; $i++) {
  $arg = $Arguments[$i]
  switch -Regex ($arg) {
    '^--help$|^-help$|^-h$|^/\?$' {
      Show-Usage
      exit 0
    }
    '^--debug$|^-debug$|^-debugmode$' {
      $debugMode = $true
      continue
    }
    '^--target$|^-target$' {
      if ($i + 1 -ge $Arguments.Count) {
        throw "Missing value for --target."
      }
      $targetPath = $Arguments[$i + 1]
      $i++
      continue
    }
    default {
      if ([string]::IsNullOrWhiteSpace($targetPath)) {
        $targetPath = $arg
      } else {
        throw "Unexpected argument: $arg"
      }
    }
  }
}

if ($env:CSI_WIZARD_DEBUG -eq "1") {
  $debugMode = $true
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wizardPath = Join-Path $scriptDir "vsc-launcher-wizard.ps1"
if (-not (Test-Path -LiteralPath $wizardPath -PathType Leaf)) {
  throw "Wizard script not found: $wizardPath"
}

if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
  if ($debugMode) {
    & $wizardPath -TargetPath $targetPath -DebugMode
  } else {
    & $wizardPath -TargetPath $targetPath
  }
} else {
  if ($debugMode) {
    & $wizardPath -DebugMode
  } else {
    & $wizardPath
  }
}
exit 0


