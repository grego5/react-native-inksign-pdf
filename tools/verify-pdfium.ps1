[CmdletBinding()]
param(
  [string]$ArchiveDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pdfiumRoot = Join-Path $root "third_party\pdfium"
$manifestPath = Join-Path $pdfiumRoot "manifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$missingPackagedLibraries = @()

if (-not $manifest.distribution.staticRelease.tag -or
    -not $manifest.distribution.staticRelease.androidAsset -or
    -not $manifest.distribution.staticRelease.iosAsset -or
    -not $manifest.distribution.staticRelease.checksumsAsset) {
  throw "FAIL static PDFium release metadata is incomplete"
}

function Get-ArchiveBytes([string]$Path) {
  return ,([System.IO.File]::ReadAllBytes($Path))
}

function Get-Sha256([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($stream)) -replace "-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
}

function Assert-StaticArchive([string]$Path, [string]$Label, [string]$ExpectedMachine) {
  $bytes = Get-ArchiveBytes $Path
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
        break
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

function Assert-ZipHasNoPdfiumSharedObject([string]$Path) {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -match '(^|/)libpdfium\.so$') {
        throw "FAIL packaged archive contains a separate libpdfium.so: $Path"
      }
    }
  } finally {
    $zip.Dispose()
  }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($artifact in $manifest.distribution.artifacts) {
  Write-Verbose "Checking $($artifact.packagedLibrary)"
  $packagedPath = Join-Path $pdfiumRoot $artifact.packagedLibrary
  if (-not (Test-Path -LiteralPath $packagedPath -PathType Leaf)) {
    $missingPackagedLibraries += $artifact.packagedLibrary
    continue
  }

  $packagedSize = (Get-Item -LiteralPath $packagedPath).Length
  if ($packagedSize -ne $artifact.packagedLibraryBytes) {
    throw "FAIL packaged size mismatch for $($artifact.packagedLibrary): $packagedSize"
  }

  $packagedHash = Get-Sha256 $packagedPath
  if ($packagedHash -ne $artifact.packagedLibrarySha256) {
    throw "FAIL packaged checksum mismatch for $($artifact.packagedLibrary)"
  }

  if ($ArchiveDirectory) {
    $archivePath = Join-Path $ArchiveDirectory $artifact.file
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
      throw "FAIL missing audit archive $($artifact.file)"
    }
    $archive = Get-Item -LiteralPath $archivePath
    $hash = Get-Sha256 $archive.FullName
    if ($hash -ne $artifact.sha256) {
      throw "FAIL checksum mismatch for $($artifact.file)"
    }
    if ($archive.Length -ne $artifact.archiveBytes) {
      throw "FAIL archive size mismatch for $($artifact.file)"
    }
  }

  if ($artifact.target -eq "android" -and $artifact.buildType -eq "static") {
    Write-Verbose "Checking archive structure and symbols"
    Assert-StaticArchive $packagedPath $artifact.packagedLibrary $artifact.expectedElfMachine
  }
}

$androidPdfiumRoot = Join-Path $pdfiumRoot "android"
$sharedLibraries = @(Get-ChildItem -LiteralPath $androidPdfiumRoot -Recurse -File -Filter "libpdfium.so" -ErrorAction SilentlyContinue)
if ($sharedLibraries.Count -ne 0) {
  throw "FAIL Android PDFium package still contains libpdfium.so"
}

$androidOutputRoots = @(
  (Join-Path $root "android"),
  (Join-Path $root "example\android")
)
$packagedArchives = @(
  foreach ($androidOutputRoot in $androidOutputRoots) {
    if (Test-Path -LiteralPath $androidOutputRoot -PathType Container) {
      Get-ChildItem -LiteralPath $androidOutputRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".aar", ".apk") }
    }
  }
)
Write-Verbose "Checking $($packagedArchives.Count) Android package archives"
foreach ($archive in $packagedArchives) {
  Assert-ZipHasNoPdfiumSharedObject $archive.FullName
}

foreach ($artifact in $manifest.distribution.artifacts | Where-Object { $_.target -eq "ios" }) {
  if ($artifact.buildType -ne "shared" -or $artifact.validation -ne "experimental-unvalidated") {
    throw "FAIL iOS artifact is not explicitly marked experimental and unvalidated"
  }
}

$iosXcframeworkRoot = Join-Path $pdfiumRoot "ios\PDFium.xcframework"
$iosStaticBinaries = @(
  (Join-Path $iosXcframeworkRoot "ios-arm64\PDFium.framework\PDFium"),
  (Join-Path $iosXcframeworkRoot "ios-arm64_x86_64-simulator\PDFium.framework\PDFium")
)
$iosStaticInstalled = Test-Path -LiteralPath $iosXcframeworkRoot -PathType Container
if ($iosStaticInstalled) {
  foreach ($iosBinary in $iosStaticBinaries) {
    if (-not (Test-Path -LiteralPath $iosBinary -PathType Leaf)) {
      $iosStaticInstalled = $false
      break
    }
    $iosBytes = Get-ArchiveBytes $iosBinary
    $iosMagic = [System.Text.Encoding]::ASCII.GetString($iosBytes[0..7])
    $isArArchive = $iosMagic -eq "!<arch>`n"
    $isFatMachO = $iosBytes.Length -ge 4 -and
      (($iosBytes[0] -eq 0xca -and $iosBytes[1] -eq 0xfe -and
        $iosBytes[2] -eq 0xba -and $iosBytes[3] -in @(0xbe, 0xbf)) -or
       ($iosBytes[0] -in @(0xbe, 0xbf) -and $iosBytes[1] -eq 0xba -and
        $iosBytes[2] -eq 0xfe -and $iosBytes[3] -eq 0xca))
    if (-not ($isArArchive -or $isFatMachO)) {
      $iosStaticInstalled = $false
      break
    }
  }
}
if ($iosStaticInstalled) {
  $iosDylibs = @(Get-ChildItem -LiteralPath $iosXcframeworkRoot -Recurse -File -Filter "*.dylib" -ErrorAction SilentlyContinue)
  if ($iosDylibs.Count -ne 0) {
    throw "FAIL static iOS XCFramework still contains a dylib"
  }
  foreach ($iosBinary in $iosStaticBinaries) {
    $iosBytes = [System.Text.Encoding]::ASCII.GetString((Get-ArchiveBytes $iosBinary))
    foreach ($symbol in @("FPDF_InitLibraryWithConfig", "FPDF_DestroyLibrary", "FPDFText_LoadPage", "FPDFPage_New")) {
      if ($iosBytes.IndexOf($symbol, [System.StringComparison]::Ordinal) -lt 0) {
        throw "FAIL static iOS archive does not contain required PDFium symbol $symbol"
      }
    }
  }
}

$requiredHeaders = @("fpdfview.h", "fpdf_text.h", "fpdf_edit.h")
foreach ($header in $requiredHeaders) {
  $headerPath = Join-Path $pdfiumRoot (Join-Path "include" $header)
  if (-not (Test-Path -LiteralPath $headerPath -PathType Leaf)) {
    throw "FAIL missing public PDFium header $header"
  }
}

$iosStatus = if ($iosStaticInstalled) {
  "static iOS XCFramework"
} else {
  "static iOS XCFramework release asset available but not installed locally"
}
if ($missingPackagedLibraries.Count -gt 0) {
  Write-Output "PASS PDFium $($manifest.version): release assets configured; local packaged copies are absent; $iosStatus"
} else {
  Write-Output "PASS PDFium $($manifest.version): static Android archives, $iosStatus, symbols, architecture, package contents, headers, and provenance are valid"
}
