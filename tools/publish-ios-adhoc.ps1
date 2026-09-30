[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
  [string] $IpaPath,

  [Parameter(Mandatory = $true, ParameterSetName = 'Remote')]
  [string] $RemoteHost,

  [Parameter(Mandatory = $true, ParameterSetName = 'Remote')]
  [string] $RemoteIpaPath,

  [Parameter(ParameterSetName = 'Remote')]
  [string] $DownloadDirectory = (Join-Path $HOME 'Downloads')
)

$ErrorActionPreference = 'Stop'
$repository = 'grego5/react-native-inksign-pdf'

function Invoke-Gh {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)

  & gh @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
  }
}

Invoke-Gh auth status --hostname github.com

if ($PSCmdlet.ParameterSetName -eq 'Remote') {
  if (-not (Test-Path -LiteralPath $DownloadDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
  }

  $fileName = [System.IO.Path]::GetFileName($RemoteIpaPath)
  if ([string]::IsNullOrWhiteSpace($fileName) -or [System.IO.Path]::GetExtension($fileName) -ne '.ipa') {
    throw 'RemoteIpaPath must point to an .ipa file.'
  }

  $IpaPath = Join-Path (Resolve-Path -LiteralPath $DownloadDirectory).Path $fileName
  & scp "${RemoteHost}:$RemoteIpaPath" $IpaPath
  if ($LASTEXITCODE -ne 0) {
    throw "Could not copy the IPA from ${RemoteHost}:$RemoteIpaPath."
  }
}

$IpaPath = (Resolve-Path -LiteralPath $IpaPath -PathType Leaf).Path
if ([System.IO.Path]::GetExtension($IpaPath) -ne '.ipa') {
  throw 'IpaPath must point to an .ipa file.'
}

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$releaseTag = "ios-devclient-local-$timestamp-$PID"
$releaseTitle = "Local iOS Ad Hoc upload $timestamp"

Invoke-Gh release create $releaseTag $IpaPath `
  --repo $repository `
  --target main `
  --draft `
  --title $releaseTitle `
  --notes 'Local IPA queued for the iOS Ad Hoc publishing workflow.'

Write-Host "Uploaded IPA as draft release $releaseTag."
Write-Host 'Dispatching the Pages/QR publishing workflow.'
Invoke-Gh workflow run ios-adhoc.yml `
  --repo $repository `
  --ref main `
  -f "reuse_release_tag=$releaseTag"

$runTitle = "iOS Ad Hoc - $releaseTag"
$run = $null
for ($attempt = 0; $attempt -lt 30 -and -not $run; $attempt++) {
  $runJson = & gh run list `
    --repo $repository `
    --workflow ios-adhoc.yml `
    --branch main `
    --event workflow_dispatch `
    --limit 20 `
    --json databaseId,displayTitle

  if ($LASTEXITCODE -ne 0) {
    throw "Could not find the publishing run for draft release $releaseTag."
  }

  $runs = @($runJson | ConvertFrom-Json)
  $run = $runs | Where-Object { $_.displayTitle -eq $runTitle } | Select-Object -First 1
  if (-not $run) {
    Start-Sleep -Seconds 2
  }
}

if (-not $run) {
  Write-Host "Retry with: gh workflow run ios-adhoc.yml --repo $repository --ref main -f reuse_release_tag=$releaseTag"
  throw "Workflow was dispatched, but its run ID was not found. Draft release $releaseTag remains available."
}

Write-Host "Watching publishing run $($run.databaseId)."
Write-Host "Workflow: https://github.com/$repository/actions/runs/$($run.databaseId)"
Invoke-Gh run watch $run.databaseId --repo $repository --exit-status
Write-Host 'Install page: https://grego5.github.io/react-native-inksign-pdf/'
