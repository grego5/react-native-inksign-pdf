[CmdletBinding(DefaultParameterSetName = "File")]
param(
  [Parameter(Mandatory, ParameterSetName = "Run")]
  [string]$RunId,

  [Parameter(Mandatory, ParameterSetName = "File")]
  [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSCmdlet.ParameterSetName -eq "Run") {
  $lines = & gh run view $RunId --log-failed
  if ($LASTEXITCODE -ne 0) {
    throw "gh run view failed for run $RunId"
  }
} else {
  $lines = Get-Content -LiteralPath $LogPath
}

$ansiEscape = [regex]::new("\x1B\[[0-9;]*[A-Za-z]")
$interesting = [regex]::new(
  '(:\s*error:|PDF signature vectorization failed|invalidStroke\(|\bXCT(?:Assert|Unwrap|Skip)|Test Case .* (?:failed|skipped)|Test Suite .* (?:failed|passed)|Executed \d+ tests|Failing tests:|\*\* TEST (?:EXECUTE )?(?:FAILED|SUCCEEDED) \*\*|##\[error\]|Process completed with exit code)',
  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$emitted = 0
foreach ($line in $lines) {
  $clean = $ansiEscape.Replace([string]$line, "")
  $timestamp = [regex]::Match($clean, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z')
  if ($timestamp.Success) {
    $clean = $clean.Substring($timestamp.Index + $timestamp.Length)
  }
  $clean = $clean.Trim()
  if ($interesting.IsMatch($clean)) {
    Write-Output $clean
    $emitted++
  }
}

if ($emitted -eq 0) {
  Write-Output "No Xcode test failures or summary lines found."
}
