[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Archive,
    [Parameter(Mandatory = $true)]
    [string]$Metadata,
    [Parameter(Mandatory = $true)]
    [ValidateSet("arm64-v8a", "armeabi-v7a", "x86", "x86_64")]
    [string]$Abi,
    [string]$LlvmBin,
    [string]$ExpectedSourceRevision,
    [string]$ExpectedNdkVersion,
    [switch]$AllowPerfettoTrace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-LlvmTool([string]$Name) {
    if (-not [string]::IsNullOrWhiteSpace($LlvmBin)) {
        $candidate = Join-Path $LlvmBin $Name
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $candidate = Join-Path $LlvmBin "$Name.exe"
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw "Required LLVM tool '$Name' was not found."
}

$archivePath = (Resolve-Path $Archive -ErrorAction Stop).Path
$metadataPath = (Resolve-Path $Metadata -ErrorAction Stop).Path
$metadataObject = Get-Content -Raw $metadataPath | ConvertFrom-Json

if ($metadataObject.abi -ne $Abi) {
    throw "Metadata ABI '$($metadataObject.abi)' does not match '$Abi'."
}
if ([int]$metadataObject.apiVersion -ne 8) {
    throw "Unsupported stroke-engine API version '$($metadataObject.apiVersion)'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
    $metadataObject.sourceRevision -ne $ExpectedSourceRevision) {
    throw "Metadata source revision '$($metadataObject.sourceRevision)' does not match '$ExpectedSourceRevision'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedNdkVersion) -and
    $metadataObject.ndkVersion -ne $ExpectedNdkVersion) {
    throw "Metadata NDK '$($metadataObject.ndkVersion)' does not match '$ExpectedNdkVersion'."
}
if (-not $AllowPerfettoTrace -and [bool]$metadataObject.perfettoTrace) {
    throw "The normal archive must have Perfetto tracing compiled out."
}

$archiveInfo = Get-Item $archivePath
if ([int64]$metadataObject.sizeBytes -ne $archiveInfo.Length) {
    throw "Metadata archive size does not match the file."
}
$actualHash = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
if ($metadataObject.sha256.ToLowerInvariant() -ne $actualHash) {
    throw "Metadata SHA-256 does not match the archive."
}

$llvmNm = Resolve-LlvmTool "llvm-nm"
$llvmAr = Resolve-LlvmTool "llvm-ar"
$llvmReadobj = Resolve-LlvmTool "llvm-readobj"

$memberOutput = & $llvmAr t $archivePath 2>&1
if ($LASTEXITCODE -ne 0 -or $memberOutput.Count -eq 0) {
    throw "LLVM archive inspection failed or returned no members."
}

$symbolOutput = (& $llvmNm --defined-only $archivePath 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "LLVM symbol inspection failed: $symbolOutput"
}
$allSymbolOutput = (& $llvmNm $archivePath 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "LLVM full symbol inspection failed: $allSymbolOutput"
}
foreach ($symbol in @(
        "nse_stroke_engine_create",
        "nse_stroke_engine_destroy",
        "nse_stroke_engine_configure_pen",
        "nse_stroke_engine_begin",
        "nse_stroke_engine_update",
        "nse_stroke_engine_end",
        "nse_stroke_engine_frame")) {
    if ($symbolOutput -notmatch [regex]::Escape($symbol)) {
        throw "Archive is missing required C ABI symbol '$symbol'."
    }
}

if (-not $AllowPerfettoTrace -and
    $allSymbolOutput -match "ATrace_(beginSection|endSection|isEnabled|setCounter)") {
    throw "Normal archive contains Android trace symbols."
}

$expectedMachine = @{
    "arm64-v8a" = "(?i)(aarch64|elf64-littleaarch64)"
    "armeabi-v7a" = "(?i)(arm|elf32-littlearm)"
    "x86" = "(?i)(i386|elf32-i386)"
    "x86_64" = "(?i)(x86_64|x86-64|elf64-x86-64)"
}[$Abi]
$headerOutput = (& $llvmReadobj --file-headers $archivePath 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $headerOutput -notmatch $expectedMachine) {
    throw "Archive object machine does not match ABI '$Abi' (expected '$expectedMachine')."
}

Write-Output "PASS: $archivePath ($Abi, $($archiveInfo.Length) bytes)"
