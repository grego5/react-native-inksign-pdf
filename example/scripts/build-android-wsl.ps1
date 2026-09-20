[CmdletBinding()]
param(
  [Alias('r')]
  [switch]$Release,
  [Alias('tr')]
  [switch]$TracingRelease,
  [Alias('i')]
  [switch]$Install,
  [Alias('ri')]
  [switch]$ReleaseInstall,
  [Alias('tri')]
  [switch]$TracingReleaseInstall
)

$ErrorActionPreference = 'Stop'

if ($ReleaseInstall) {
  $Release = $true
  $Install = $true
}

if ($TracingReleaseInstall) {
  $TracingRelease = $true
  $Install = $true
}

$exampleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot 'build-android-wsl.sh')).Path

$configuration = if ($Release -or $TracingRelease) { 'Release' } else { 'Debug' }
$variant = $configuration.ToLowerInvariant()
$wslPrefix = @()

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw 'wsl.exe was not found. Install WSL before running this script.'
}

function ConvertTo-WslPath([string]$WindowsPath) {
  $wslPathArgument = $WindowsPath.Replace('\', '/')
  $rawOutput = @(& wsl.exe @wslPrefix -- wslpath -a -u -- $wslPathArgument 2>&1)
  $exitCode = $LASTEXITCODE
  $outputLines = @(
    $rawOutput |
      ForEach-Object { "$($_)".Trim() } |
      Where-Object { $_ }
  )

  if ($exitCode -ne 0 -or $outputLines.Count -eq 0) {
    $details = ($rawOutput -join ' ').Trim()
    if (-not $details) {
      $details = 'wslpath returned no output.'
    }
    throw "Unable to convert '$WindowsPath' through WSL. $details"
  }

  return $outputLines[-1]
}

$sourcePath = ConvertTo-WslPath $exampleRoot
$wslScriptPath = ConvertTo-WslPath $scriptPath
$outputPath = Join-Path $exampleRoot "build\app-$variant.apk"
$wslOutputPath = ConvertTo-WslPath $outputPath

$scriptArguments = @(
  $wslScriptPath,
  '--source', $sourcePath,
  '--task', ":app:assemble$configuration",
  '--variant', $variant,
  '--output', $wslOutputPath
)

if ($TracingRelease) {
  $scriptArguments += '--tracing'
}

& wsl.exe @wslPrefix -- bash @scriptArguments
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

if ($Install) {
  if (-not (Get-Command adb.exe -ErrorAction SilentlyContinue)) {
    throw 'adb.exe was not found on Windows PATH. Install Android platform-tools or add its directory to PATH.'
  }

  $deviceLine = @(
    & adb.exe devices |
      Where-Object { "$_" -match '^\S+\s+device\s*$' }
  ) | Select-Object -First 1

  if (-not $deviceLine) {
    throw 'No Android device is connected and authorized for adb.exe.'
  }

  $deviceSerial = ($deviceLine -split '\s+')[0]
  Write-Host "Installing $outputPath on $deviceSerial"
  & adb.exe -s $deviceSerial install -r $outputPath
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}
