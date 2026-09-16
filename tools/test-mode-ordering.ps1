[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$androidPath = Join-Path $root "android\src\main\java\com\margelo\nitro\inksignpdf\HybridPdfView.kt"
$androidSessionPath = Join-Path $root "android\src\main\java\com\margelo\nitro\inksignpdf\PdfSession.kt"
$androidPolicyPath = Join-Path $root "android\src\main\java\com\margelo\nitro\inksignpdf\CacheArtifactPolicy.kt"
$iosPath = Join-Path $root "ios\PdfView+Document.swift"

$android = Get-Content -LiteralPath $androidPath -Raw
$androidSession = Get-Content -LiteralPath $androidSessionPath -Raw
$androidPolicy = Get-Content -LiteralPath $androidPolicyPath -Raw
$ios = Get-Content -LiteralPath $iosPath -Raw

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -match $Pattern) { throw "FAIL $Name" }
}

function Assert-Ordered([string]$Text, [string]$First, [string]$Second, [string]$Name) {
    $firstIndex = $Text.IndexOf($First)
    $secondIndex = $Text.IndexOf($Second)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -ge $secondIndex) {
        throw "FAIL $Name"
    }
}

$androidStart = $android.IndexOf("private fun enterMode")
$androidBody = $android.Substring($androidStart)
Assert-Contains $androidBody 'ViewportRequestParser\.parse\(viewport\)' 'Android parses mode options'
Assert-Contains $androidBody 'surface\.requireModeTransitionReady\(\)' 'Android checks mode readiness'
Assert-Ordered $androidBody 'ViewportRequestParser.parse(viewport)' 'viewportRequestID += 1L' 'Android accepts after validation'

$replaceStart = $androidSession.IndexOf('private fun replaceOnWorker')
$replaceBody = $androidSession.Substring($replaceStart)
Assert-Contains $replaceBody 'if \(isStale\(generation\)\)' 'Android stale open is checked'
Assert-NotContains $replaceBody 'previousSource|deleteRecursively|retireSource' 'Android replacement does not clean sources'
Assert-NotContains $android 'managedRoot|managedSources|managedSource' 'Android has no managed-source ownership'
Assert-Contains $androidPolicy 'signed-.*\.pdf' 'Android cache policy owns signed outputs'
Assert-Contains $androidPolicy 'EXPORT_SCRATCH' 'Android cache policy owns export scratch'
Assert-Contains $androidSession 'retireOutput' 'Android disposal retires exact outputs'

$iosStart = $ios.IndexOf('private func transition(toEditing: Bool')
$iosBody = $ios.Substring($iosStart)
Assert-Contains $iosBody 'Self\.parseViewport\(viewport\)' 'iOS parses mode options'
Assert-Contains $iosBody 'self\.requireViewportReady\(request: request\)' 'iOS checks mode readiness'
Assert-Ordered $iosBody 'Self.parseViewport(viewport)' 'self.viewportRequestID &+= 1' 'iOS accepts after validation'

Write-Output "PASS native mode acceptance ordering checks"
