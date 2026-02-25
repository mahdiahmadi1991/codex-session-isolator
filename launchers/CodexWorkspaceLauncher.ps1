param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$TargetPath,
  [switch]$DryRun
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$newScript = Join-Path $scriptDir "CodexSessionIsolator.ps1"

if ($DryRun) {
  & $newScript -TargetPath $TargetPath -DryRun
} else {
  & $newScript -TargetPath $TargetPath
}
