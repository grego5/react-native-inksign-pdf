[CmdletBinding()]
param(
  [ValidateSet("metadata", "local", "release")]
  [string]$Mode = "metadata",
  [ValidateSet("android")]
  [string]$Platform = "android",
  [string]$ArchiveDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ArchiveDirectory -and $Mode -eq "metadata") { $Mode = "release" }
if ($Mode -eq "release" -and -not $ArchiveDirectory) {
  throw "FAIL release verification requires -ArchiveDirectory with the pinned Android PDFium assets"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pdfiumRoot = Join-Path $root "core\third_party\pdfium"
$manifest = Get-Content -LiteralPath (Join-Path $pdfiumRoot "manifest.json") -Raw | ConvertFrom-Json
$staticRelease = $manifest.distribution.staticRelease
$requiredSymbols = @($manifest.upstream.requiredSymbols)
$requiredHeaders = @($manifest.upstream.publicHeaders)
$androidArtifacts = @($staticRelease.artifacts | Where-Object {
  $_.target -eq "android" -and $_.buildType -eq "static"
})

if ($requiredSymbols.Count -eq 0 -or $requiredHeaders.Count -eq 0) {
  throw "FAIL PDFium metadata does not declare required symbols and public headers"
}
if (-not $staticRelease.tag -or -not $staticRelease.androidAsset -or
    -not $staticRelease.androidAssetSha256 -or -not $staticRelease.checksumsAsset -or
    -not $staticRelease.checksumsAssetSha256) {
  throw "FAIL Android PDFium release metadata is incomplete"
}
if (@($staticRelease.artifacts | Where-Object { $_.target -ne "android" }).Count -ne 0) {
  throw "FAIL PDFium package metadata must contain Android artifacts only"
}
$expectedAbis = @("arm64-v8a", "x86_64")
$actualAbis = @($androidArtifacts | ForEach-Object { $_.abi } | Sort-Object -Unique)
if (@(Compare-Object ($expectedAbis | Sort-Object) $actualAbis).Count -ne 0 -or
    $androidArtifacts.Count -ne $expectedAbis.Count) {
  throw "FAIL static PDFium artifacts must contain arm64-v8a and x86_64 only"
}

foreach ($header in $requiredHeaders) {
  $path = Join-Path $pdfiumRoot (Join-Path "include" $header)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "FAIL missing public PDFium header $header"
  }
}

function Get-FileSha256([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($stream)) -replace "-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

function Assert-FileHashAndSize([string]$Path,
                               [string]$ExpectedHash,
                               [long]$ExpectedBytes,
                               [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "FAIL missing $Label" }
  $item = Get-Item -LiteralPath $Path
  if ($ExpectedBytes -gt 0 -and $item.Length -ne $ExpectedBytes) {
    throw "FAIL $Label size mismatch: $($item.Length)"
  }
  $actualHash = Get-FileSha256 $Path
  if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
    throw "FAIL $Label checksum mismatch: expected $ExpectedHash, got $actualHash"
  }
}

function Assert-StaticAndroidArchive([string]$Path,
                                     [string]$Label,
                                     [string]$ExpectedMachine) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>`n") {
    throw "FAIL $Label is not an ar static archive"
  }
  $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
  foreach ($symbol in $requiredSymbols) {
    if ($ascii.IndexOf($symbol, [System.StringComparison]::Ordinal) -lt 0) {
      throw "FAIL $Label does not contain required PDFium symbol $symbol"
    }
  }

  $expectedElfMachine = if ($ExpectedMachine -eq "AARCH64") { 0x00b7 } else { 0x003e }
  $memberOffset = 8
  $matchedArchitecture = $false
  while ($memberOffset -le $bytes.Length - 60) {
    $memberSizeText = [System.Text.Encoding]::ASCII.GetString($bytes, $memberOffset + 48, 10).Trim()
    [long]$memberSize = 0
    if (-not [long]::TryParse($memberSizeText,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$memberSize)) {
      throw "FAIL $Label contains an invalid ar member header"
    }
    $memberDataOffset = $memberOffset + 60
    if ($memberDataOffset + 20 -le $bytes.Length -and
        $bytes[$memberDataOffset] -eq 0x7f -and
        $bytes[$memberDataOffset + 1] -eq 0x45 -and
        $bytes[$memberDataOffset + 2] -eq 0x4c -and
        $bytes[$memberDataOffset + 3] -eq 0x46) {
      $machine = ($bytes[$memberDataOffset + 19] -shl 8) -bor $bytes[$memberDataOffset + 18]
      if ($machine -eq $expectedElfMachine) { $matchedArchitecture = $true }
    }
    $memberOffset = $memberDataOffset + $memberSize
    if (($memberOffset % 2) -ne 0) { $memberOffset++ }
  }
  if (-not $matchedArchitecture) {
    throw "FAIL $Label has no ELF object for $ExpectedMachine"
  }
}

function Assert-InstalledAndroid {
  foreach ($artifact in $androidArtifacts) {
    $path = Join-Path $root $artifact.packagedLibrary
    Assert-FileHashAndSize $path $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes $artifact.packagedLibrary
    Assert-StaticAndroidArchive $path $artifact.packagedLibrary $artifact.expectedElfMachine
  }
  $sharedLibraries = @(Get-ChildItem -LiteralPath (Join-Path $root "android\build\pdfium") -Recurse -File -Filter "libpdfium.so" -ErrorAction SilentlyContinue)
  if ($sharedLibraries.Count -ne 0) { throw "FAIL Android PDFium package contains a shared libpdfium.so" }
}

function Assert-ReleaseArchive {
  $checksums = Join-Path $ArchiveDirectory $staticRelease.checksumsAsset
  $androidArchive = Join-Path $ArchiveDirectory $staticRelease.androidAsset
  Assert-FileHashAndSize $checksums $staticRelease.checksumsAssetSha256 $staticRelease.checksumsAssetBytes "PDFium checksum list"
  Assert-FileHashAndSize $androidArchive $staticRelease.androidAssetSha256 $staticRelease.androidAssetBytes "PDFium Android release asset"
  $checksumLine = Get-Content -LiteralPath $checksums | Where-Object {
    $_.Trim().EndsWith("  $($staticRelease.androidAsset)") -or
      $_.Trim().EndsWith(" *$($staticRelease.androidAsset)")
  } | Select-Object -First 1
  if (-not $checksumLine -or $checksumLine.Trim().Split()[0].ToLowerInvariant() -ne
      $staticRelease.androidAssetSha256.ToLowerInvariant()) {
    throw "FAIL checksum list does not match the Android PDFium release asset"
  }

  $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("inksign-pdfium-verify-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
  try {
    Expand-Archive -LiteralPath $androidArchive -DestinationPath $temporaryDirectory
    foreach ($artifact in $androidArtifacts) {
      $candidate = @(Get-ChildItem -LiteralPath $temporaryDirectory -Recurse -File -Filter "*.a" |
        Where-Object { $_.FullName -match [regex]::Escape($artifact.abi) }) | Select-Object -First 1
      if (-not $candidate) { throw "FAIL release archive is missing ABI $($artifact.abi)" }
      Assert-FileHashAndSize $candidate.FullName $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes "Android release $($artifact.abi) archive"
      Assert-StaticAndroidArchive $candidate.FullName "Android release $($artifact.abi)" $artifact.expectedElfMachine
    }
  } finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Mode -eq "release") {
  Assert-ReleaseArchive
  Write-Output "PASS Android PDFium $($manifest.version): pinned static release assets, ABIs, symbols, and headers are valid"
} elseif ($Mode -eq "local") {
  Assert-InstalledAndroid
  Write-Output "PASS Android PDFium $($manifest.version): local static archives, ABIs, symbols, and headers are valid"
} else {
  Write-Output "PASS Android PDFium $($manifest.version): Android-only artifact metadata and public headers are valid"
}
