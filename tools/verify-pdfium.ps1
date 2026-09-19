[CmdletBinding()]
param(
  [ValidateSet("metadata", "local", "release")]
  [string]$Mode = "metadata",
  [ValidateSet("all", "android", "ios")]
  [string]$Platform = "all",
  [string]$ArchiveDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ArchiveDirectory -and $Mode -eq "metadata") {
  $Mode = "release"
}
if ($Mode -eq "release" -and -not $ArchiveDirectory) {
  throw "FAIL release verification requires -ArchiveDirectory containing the pinned PDFium release assets"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pdfiumRoot = Join-Path $root "third_party\pdfium"
$manifestPath = Join-Path $pdfiumRoot "manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$staticRelease = $manifest.distribution.staticRelease

if (-not $staticRelease.tag -or -not $staticRelease.androidAsset -or
    -not $staticRelease.androidAssetSha256 -or -not $staticRelease.iosAsset -or
    -not $staticRelease.iosAssetSha256 -or -not $staticRelease.checksumsAsset -or
    -not $staticRelease.checksumsAssetSha256) {
  throw "FAIL static PDFium release metadata is incomplete"
}

$expectedArtifacts = @(
  "android:arm64-v8a",
  "android:x86_64",
  "ios:ios-arm64",
  "ios:ios-arm64_x86_64-simulator"
)
$actualArtifacts = @(
  foreach ($artifact in @($staticRelease.artifacts)) {
    if ($artifact.buildType -ne "static") {
      throw "FAIL authoritative PDFium artifact $($artifact.target) must be static"
    }
    if ($artifact.target -eq "android") {
      $expectedMachine = if ($artifact.abi -eq "arm64-v8a") { "AARCH64" } else { "X86_64" }
      if ($artifact.expectedElfMachine -ne $expectedMachine) {
        throw "FAIL Android PDFium artifact $($artifact.abi) has incorrect architecture metadata"
      }
      "android:$($artifact.abi)"
    } elseif ($artifact.target -eq "ios") {
      $expectedArchitectures = if ($artifact.slice -eq "ios-arm64") {
        @("arm64")
      } else {
        @("arm64", "x86_64")
      }
      $actualArchitectures = @($artifact.architectures | Sort-Object)
      if (@(Compare-Object ($expectedArchitectures | Sort-Object) $actualArchitectures).Count -ne 0) {
        throw "FAIL iOS PDFium artifact $($artifact.slice) has incorrect architecture metadata"
      }
      "ios:$($artifact.slice)"
    } else {
      throw "FAIL unsupported PDFium static artifact target $($artifact.target)"
    }
  }
)
if ($actualArtifacts.Count -ne $expectedArtifacts.Count -or
    @($actualArtifacts | Sort-Object -Unique).Count -ne $actualArtifacts.Count -or
    @(Compare-Object ($expectedArtifacts | Sort-Object) ($actualArtifacts | Sort-Object)).Count -ne 0) {
  throw "FAIL static PDFium artifact set must be exactly: $($expectedArtifacts -join ', ')"
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

function Get-FileBytes([string]$Path) {
  return ,([System.IO.File]::ReadAllBytes($Path))
}

function Assert-FileHashAndSize([string]$Path, [string]$ExpectedHash, [long]$ExpectedBytes, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "FAIL missing $Label"
  }
  $item = Get-Item -LiteralPath $Path
  if ($ExpectedBytes -gt 0 -and $item.Length -ne $ExpectedBytes) {
    throw "FAIL $Label size mismatch: $($item.Length)"
  }
  $actual = Get-FileSha256 $Path
  if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
    throw "FAIL $Label checksum mismatch: expected $ExpectedHash, got $actual"
  }
}

function Assert-StaticArchive([string]$Path, [string]$Label, [string]$ExpectedMachine) {
  $bytes = Get-FileBytes $Path
  if ($bytes.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>`n") {
    throw "FAIL $Label is not an ar static archive"
  }

  $hasExpectedMachine = $false
  $hasElfObject = $false
  $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
  foreach ($symbol in @(
      "FPDF_InitLibraryWithConfig",
      "FPDF_DestroyLibrary",
      "FPDFText_LoadPage",
      "FPDFPage_New"
    )) {
    if ($ascii.IndexOf($symbol, [System.StringComparison]::Ordinal) -lt 0) {
      throw "FAIL $Label does not contain required PDFium symbol $symbol"
    }
  }

  $memberOffset = 8
  while ($memberOffset -le $bytes.Length - 60) {
    $memberSizeText = [System.Text.Encoding]::ASCII.GetString($bytes, $memberOffset + 48, 10).Trim()
    [long]$memberSize = 0
    if (-not [long]::TryParse($memberSizeText, [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$memberSize)) {
      throw "FAIL $Label contains an invalid ar member header"
    }

    $memberDataOffset = $memberOffset + 60
    if ($memberDataOffset + 20 -le $bytes.Length -and
        $bytes[$memberDataOffset] -eq 0x7f -and
        $bytes[$memberDataOffset + 1] -eq 0x45 -and
        $bytes[$memberDataOffset + 2] -eq 0x4c -and
        $bytes[$memberDataOffset + 3] -eq 0x46) {
      $hasElfObject = $true
      $machine = ($bytes[$memberDataOffset + 19] -shl 8) -bor $bytes[$memberDataOffset + 18]
      if (($ExpectedMachine -eq "AARCH64" -and $machine -eq 0x00b7) -or
          ($ExpectedMachine -eq "X86_64" -and $machine -eq 0x003e)) {
        $hasExpectedMachine = $true
      }
    }

    $memberOffset = $memberDataOffset + $memberSize
    if (($memberOffset % 2) -ne 0) {
      $memberOffset++
    }
  }

  if (-not $hasElfObject) {
    throw "FAIL $Label contains no ELF object members"
  }
  if (-not $hasExpectedMachine) {
    throw "FAIL $Label does not contain an ELF object for $ExpectedMachine"
  }
}

function Assert-IosStaticBinary([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "FAIL missing $Label"
  }
  $bytes = Get-FileBytes $Path
  $isArArchive = $bytes.Length -ge 8 -and
    [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8) -eq "!<arch>`n"
  if (-not $isArArchive) {
    if ($bytes.Length -lt 8) {
      throw "FAIL $Label is not a static archive"
    }

    $magic = [System.BitConverter]::ToUInt32(@($bytes[3], $bytes[2], $bytes[1], $bytes[0]), 0)
    $is64Bit = $magic -in @(0xcafebabf, 0xbfbafeca)
    $isSwapped = $magic -in @(0xbebafeca, 0xbfbafeca)
    if (-not $is64Bit -and $magic -notin @(0xcafebabe, 0xbebafeca)) {
      throw "FAIL $Label is not a static archive or universal binary"
    }

    function Read-FatUInt32([byte[]]$Data, [int]$Offset, [bool]$Swapped) {
      $valueBytes = if ($Swapped) {
        @($Data[$Offset], $Data[$Offset + 1], $Data[$Offset + 2], $Data[$Offset + 3])
      } else {
        @($Data[$Offset + 3], $Data[$Offset + 2], $Data[$Offset + 1], $Data[$Offset])
      }
      return [System.BitConverter]::ToUInt32([byte[]]$valueBytes, 0)
    }

    function Read-FatUInt64([byte[]]$Data, [int]$Offset, [bool]$Swapped) {
      $valueBytes = if ($Swapped) {
        @($Data[$Offset], $Data[$Offset + 1], $Data[$Offset + 2], $Data[$Offset + 3],
          $Data[$Offset + 4], $Data[$Offset + 5], $Data[$Offset + 6], $Data[$Offset + 7])
      } else {
        @($Data[$Offset + 7], $Data[$Offset + 6], $Data[$Offset + 5], $Data[$Offset + 4],
          $Data[$Offset + 3], $Data[$Offset + 2], $Data[$Offset + 1], $Data[$Offset])
      }
      return [System.BitConverter]::ToUInt64([byte[]]$valueBytes, 0)
    }

    $architectureCount = Read-FatUInt32 $bytes 4 $isSwapped
    $recordSize = if ($is64Bit) { 32 } else { 20 }
    if ($architectureCount -eq 0 -or 8 + $architectureCount * $recordSize -gt $bytes.Length) {
      throw "FAIL $Label has an invalid universal-binary header"
    }
    for ($index = 0; $index -lt $architectureCount; $index++) {
      $recordOffset = 8 + $index * $recordSize
      [uint64]$sliceOffset = if ($is64Bit) {
        Read-FatUInt64 $bytes ($recordOffset + 8) $isSwapped
      } else {
        Read-FatUInt32 $bytes ($recordOffset + 8) $isSwapped
      }
      if ($sliceOffset + 8 -gt $bytes.Length -or
          [System.Text.Encoding]::ASCII.GetString($bytes, [int]$sliceOffset, 8) -ne "!<arch>`n") {
        throw "FAIL $Label contains a non-static universal slice at index $index"
      }
    }
  }

  $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
  foreach ($symbol in @(
      "FPDF_InitLibraryWithConfig",
      "FPDF_DestroyLibrary",
      "FPDFText_LoadPage",
      "FPDFPage_New"
    )) {
    if ($ascii.IndexOf($symbol, [System.StringComparison]::Ordinal) -lt 0) {
      throw "FAIL $Label does not contain required PDFium symbol $symbol"
    }
  }
}

function Assert-Headers {
  foreach ($header in @("fpdfview.h", "fpdf_text.h", "fpdf_edit.h")) {
    $headerPath = Join-Path $pdfiumRoot (Join-Path "include" $header)
    if (-not (Test-Path -LiteralPath $headerPath -PathType Leaf)) {
      throw "FAIL missing public PDFium header $header"
    }
  }
}

function Get-StaticAndroidArtifacts {
  return @($staticRelease.artifacts | Where-Object {
    $_.target -eq "android" -and $_.buildType -eq "static"
  })
}

function Assert-InstalledAndroid {
  foreach ($artifact in Get-StaticAndroidArtifacts) {
    $path = Join-Path $root $artifact.packagedLibrary
    Assert-FileHashAndSize $path $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes $artifact.packagedLibrary
    Assert-StaticArchive $path $artifact.packagedLibrary $artifact.expectedElfMachine
  }
  $androidPdfiumRoot = Join-Path $root "android\build\pdfium"
  $sharedLibraries = @(Get-ChildItem -LiteralPath $androidPdfiumRoot -Recurse -File -Filter "libpdfium.so" -ErrorAction SilentlyContinue)
  if ($sharedLibraries.Count -ne 0) {
    throw "FAIL Android PDFium package still contains libpdfium.so"
  }
}

function Assert-InstalledIos {
  foreach ($artifact in @($staticRelease.artifacts | Where-Object { $_.target -eq "ios" })) {
    $path = Join-Path $root $artifact.packagedLibrary
    Assert-FileHashAndSize $path $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes $artifact.packagedLibrary
    Assert-IosStaticBinary $path "iOS $($artifact.slice) PDFium binary"
  }
  $iosXcframeworkRoot = Join-Path $root "ios\build\PDFium.xcframework"
  $iosDylibs = @(Get-ChildItem -LiteralPath $iosXcframeworkRoot -Recurse -File -Filter "*.dylib" -ErrorAction SilentlyContinue)
  if ($iosDylibs.Count -ne 0) {
    throw "FAIL static iOS XCFramework still contains a dylib"
  }
}

function Assert-ArchiveDirectory {
  $checksums = Join-Path $ArchiveDirectory $staticRelease.checksumsAsset
  $androidArchive = Join-Path $ArchiveDirectory $staticRelease.androidAsset
  $iosArchive = Join-Path $ArchiveDirectory $staticRelease.iosAsset
  Assert-FileHashAndSize $checksums $staticRelease.checksumsAssetSha256 $staticRelease.checksumsAssetBytes "PDFium checksum list"
  Assert-FileHashAndSize $androidArchive $staticRelease.androidAssetSha256 $staticRelease.androidAssetBytes "PDFium Android release asset"
  Assert-FileHashAndSize $iosArchive $staticRelease.iosAssetSha256 $staticRelease.iosAssetBytes "PDFium iOS release asset"

  $expectedHashes = @{
    $staticRelease.androidAsset = $staticRelease.androidAssetSha256.ToLowerInvariant()
    $staticRelease.iosAsset = $staticRelease.iosAssetSha256.ToLowerInvariant()
  }
  $checksumText = Get-Content -LiteralPath $checksums -Raw
  foreach ($asset in $expectedHashes.Keys) {
    $line = $checksumText -split "`r?`n" | Where-Object {
      $_.Trim().EndsWith("  $asset") -or $_.Trim().EndsWith(" *$asset")
    } | Select-Object -First 1
    if (-not $line) {
      throw "FAIL PDFium checksum list is missing $asset"
    }
    $listed = $line.Trim().Split()[0].ToLowerInvariant()
    if ($listed -ne $expectedHashes[$asset]) {
      throw "FAIL PDFium checksum-list entry mismatch for $asset"
    }
  }

  $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("inksign-pdfium-verify-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
  try {
    $androidExtracted = Join-Path $temporaryDirectory "android"
    $iosExtracted = Join-Path $temporaryDirectory "ios"
    New-Item -ItemType Directory -Path $androidExtracted, $iosExtracted | Out-Null
    Expand-Archive -LiteralPath $androidArchive -DestinationPath $androidExtracted
    & tar -xzf $iosArchive -C $iosExtracted
    if ($LASTEXITCODE -ne 0) {
      throw "FAIL unable to extract PDFium iOS release asset"
    }

    foreach ($artifact in Get-StaticAndroidArtifacts) {
      $candidate = @(Get-ChildItem -LiteralPath $androidExtracted -Recurse -File -Filter "*.a" |
        Where-Object { $_.FullName -match [regex]::Escape($artifact.abi) }) | Select-Object -First 1
      if (-not $candidate) {
        throw "FAIL Android release asset is missing the $($artifact.abi) static archive"
      }
      Assert-FileHashAndSize $candidate.FullName $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes "Android release $($artifact.abi) archive"
      Assert-StaticArchive $candidate.FullName "Android release $($artifact.abi)" $artifact.expectedElfMachine
    }

    $iosRoot = @(Get-ChildItem -LiteralPath $iosExtracted -Recurse -Directory -Filter "PDFium.xcframework") | Select-Object -First 1
    if (-not $iosRoot) {
      throw "FAIL iOS release asset is missing PDFium.xcframework"
    }
    foreach ($artifact in @($staticRelease.artifacts | Where-Object { $_.target -eq "ios" })) {
      $relativePath = $artifact.packagedLibrary -replace '^ios/build/PDFium\.xcframework[\\/]', ''
      $binary = Join-Path $iosRoot.FullName $relativePath
      Assert-FileHashAndSize $binary $artifact.packagedLibrarySha256 $artifact.packagedLibraryBytes "iOS release $($artifact.slice) archive"
      Assert-IosStaticBinary $binary "iOS release $($artifact.slice)"
    }
  } finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Assert-Headers

if ($Mode -eq "release") {
  Assert-ArchiveDirectory
  Write-Output "PASS PDFium $($manifest.version): pinned Android and iOS release assets, static archives, symbols, architectures, and headers are valid"
  exit 0
}

if ($Mode -eq "local") {
  if ($Platform -in @("all", "android")) {
    Assert-InstalledAndroid
  }
  if ($Platform -in @("all", "ios")) {
    Assert-InstalledIos
  }
  Write-Output "PASS PDFium $($manifest.version): requested local $Platform artifacts, static archives, symbols, architectures, and headers are valid"
  exit 0
}

$androidInstalled = $true
try { Assert-InstalledAndroid } catch { $androidInstalled = $false }
$iosInstalled = $true
try { Assert-InstalledIos } catch { $iosInstalled = $false }
$available = @()
if ($androidInstalled) { $available += "Android" }
if ($iosInstalled) { $available += "iOS" }
$availableText = if ($available.Count -gt 0) { $available -join ", " } else { "none" }
Write-Output "SKIP PDFium $($manifest.version): metadata and pinned release records are valid; locally installed static artifacts available: $availableText. Use -Mode local to require installed artifacts or -Mode release -ArchiveDirectory <dir> to validate release assets."
