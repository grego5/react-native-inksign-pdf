[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Read-Source([string]$RelativePath) {
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "FAIL missing source $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Require([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Forbid([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -match $Pattern) { throw "FAIL $Name" }
}

$androidPolicy = Read-Source "android/src/main/java/com/margelo/nitro/inksignpdf/CacheArtifactPolicy.kt"
$androidView = Read-Source "android/src/main/java/com/margelo/nitro/inksignpdf/HybridInkSignView.kt"
$androidWorker = Read-Source "android/src/main/java/com/margelo/nitro/inksignpdf/PdfSession.kt"
$androidExport = Read-Source "android/src/main/java/com/margelo/nitro/inksignpdf/PdfExport.kt"
$androidPackage = Read-Source "android/src/main/java/com/margelo/nitro/inksignpdf/ReactNativeInkSignPdfPackage.kt"
$iosPolicy = Read-Source "ios/CacheArtifacts.swift"
$iosView = Read-Source "ios/InkSignView.swift"
$iosDocument = Read-Source "ios/InkSignView+Document.swift"
$iosExport = Read-Source "ios/InkSignView+Export.swift"
$iosStartup = Read-Source "ios/ReactNativeInkSignPdfStartup.m"
$example = Read-Source "example/src/App.tsx"
$readme = Read-Source "README.md"

Require $androidPolicy 'DEFAULT_DIRECTORY_NAME\s*=\s*"inksignpdf"' 'Android default leaf'
Require $androidPolicy 'CACHE_DIRECTORY_NAME_METADATA' 'Android manifest override'
Require $androidPolicy 'context\.cacheDir' 'Android cache root'
Require $androidPolicy 'root\.listFiles\(\)' 'Android direct startup scan'
Require $androidPolicy 'BuildConfig\.DEBUG' 'Android debug-only classifier'
Require $androidPolicy 'SIGNED_OUTPUT' 'Android signed classifier'
Require $androidPolicy 'EXPORT_SCRATCH' 'Android scratch classifier'
Require $androidPolicy 'DEBUG_RECORDING' 'Android debug classifier'
Require $androidPackage 'CacheArtifactPolicy\.initialize' 'Android package startup gate'
Require $androidView 'artifactPolicy\.allocateSignedOutput\(\)' 'Android managed output allocation'
Require $androidView 'pendingOutputs|ownedOutputs' 'Android request/view output ownership'
Require $androidView 'pdfWorker\.close\(outputs, artifactPolicy::deleteExact\)' 'Android disposal uses policy deletion'
Require $androidView 'normalizeFinalizeError' 'Android finalize errors are normalized'
Require $androidView 'cache_unavailable' 'Android cache allocation errors are mapped'
Require $androidWorker 'retireOutput' 'Android worker output retirement callback'
Require $androidExport 'artifactPolicy\.allocateExportScratch\(\)' 'Android operation scratch allocation'
Require $androidExport 'artifactPolicy(\\.deleteExact|::deleteExact)' 'Android operation scratch cleanup'
Forbid $androidView 'managedRoot|managedSources|managedSource' 'Android managed-source machinery removed'
Forbid $androidWorker 'sources\.forEach' 'Android worker does not delete caller sources'
Forbid $androidExport 'source-.*\.pdf|source\.parentFile' 'Android export is not source-derived'

Require $iosPolicy 'static let shared' 'iOS process-wide policy'
Require $iosPolicy 'ReactNativeInkSignPdfCacheDirectoryName' 'iOS Info.plist override'
Require $iosPolicy 'contentsOfDirectory' 'iOS direct startup scan'
Require $iosPolicy 'signedOutputPattern' 'iOS signed classifier'
Require $iosPolicy 'exportScratchPattern' 'iOS scratch classifier'
Require $iosPolicy 'verificationScratchPattern' 'iOS verification classifier'
Require $iosPolicy 'deleteExact' 'iOS exact deletion'
Require $iosStartup 'constructor' 'iOS image startup hook'
Require $iosView 'pendingOutputURLs|ownedOutputURLs' 'iOS request/view output ownership'
Require $iosView 'exportQueue\.async' 'iOS off-main output retirement'
Require $iosExport 'artifactPolicy\.allocateSignedOutput\(\)' 'iOS managed output allocation'
Require $iosExport 'policy\.allocateExportScratch\(\)' 'iOS operation scratch allocation'
Require $iosExport 'policy\.allocateVerificationScratch\(\)' 'iOS verification scratch allocation'
Require $iosExport 'policy\.deleteExact' 'iOS operation scratch cleanup'
Require $iosExport 'normalizeExportError' 'iOS finalize errors are normalized'
Require $iosExport 'if let exportError = error as\? ExportError' 'iOS public export errors are preserved'
Forbid $iosView 'managedSourceURL|sourceLifetime|sourceLease|managedSourceLifetimes' 'iOS managed-source machinery removed'
Forbid $iosDocument 'managedSourceURL|sourceLifetime|sourceLease|removeManagedSource' 'iOS document source cleanup removed'
Forbid $iosExport 'managedSourceURL|sourceLifetime|sourceLease|removeManagedSource|source\.deletingLastPathComponent\(\)' 'iOS export is not source-derived'

Forbid $example 'workingDirectory|uniqueSourceName|source-\$' 'example has no second source copy'
Require $example 'keepLocalCopy' 'example retains picker-owned local copy workflow'
Require $example 'cleanupLocalFile' 'example can retire picker copies'
Require $example 'useEffect' 'example cleans picker copies on unmount'
Require $example 'cleanupLocalFile' 'example retires exact picker paths'
Require $example 'cleanupLocalFile' 'example uses one picker-path cleanup helper'
Require $example 'const previousPath = selectedPdf\.current\?\.path' 'example captures the exact previous source'
Require $example 'cleanupLocalFile\(previousPath' 'example retires the previous source after replacement'
Require $example 'if \(pickerPath !== previousPath\) cleanupLocalFile\(pickerPath' 'example retires failed-open candidates'
Require $example 'saveDocuments' 'example copies signed output to caller destination'
Require $example 'copy:\s*true' 'example requests durable output copy'
Require $readme 'caller-owned' 'public source ownership documentation'
Require $readme 'before\s+unmount' 'public output lifetime documentation'
Require $readme 'CACHE_DIRECTORY_NAME|ReactNativeInkSignPdfCacheDirectoryName' 'public cache override documentation'

Write-Output "PASS managed artifact parity: Android and iOS use contained process-once policies, direct caller sources, and request-owned outputs"
