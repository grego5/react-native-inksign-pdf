[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$specPath = Join-Path $root "src\PdfView.nitro.ts"
$indexPath = Join-Path $root "src\index.ts"
$androidSpecPath = Join-Path $root "nitrogen\generated\android\kotlin\com\margelo\nitro\inksignpdf\HybridPdfViewSpec.kt"
$iosSpecPath = Join-Path $root "nitrogen\generated\ios\swift\HybridPdfViewSpec.swift"
$androidViewPath = Join-Path $root "android\src\main\java\com\margelo\nitro\inksignpdf\HybridPdfView.kt"
$iosDocumentPath = Join-Path $root "ios\PdfView+Document.swift"

$spec = Get-Content -LiteralPath $specPath -Raw
$index = Get-Content -LiteralPath $indexPath -Raw
$androidSpec = Get-Content -LiteralPath $androidSpecPath -Raw
$iosSpec = Get-Content -LiteralPath $iosSpecPath -Raw
$androidView = Get-Content -LiteralPath $androidViewPath -Raw
$iosDocument = Get-Content -LiteralPath $iosDocumentPath -Raw

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -match $Pattern) { throw "FAIL $Name" }
}

function Get-NumericFields([string]$Text, [string]$InterfaceName) {
    $match = [regex]::Match(
        $Text,
        "interface\s+$InterfaceName\s*\{(?<body>.*?)\}",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) { throw "FAIL missing $InterfaceName" }
    return @(
        [regex]::Matches($match.Groups['body'].Value, '(?m)^\s*(\w+)\??:\s*number\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )
}

$viewportFields = @(Get-NumericFields $spec 'Viewport')
$optionFields = @(Get-NumericFields $spec 'ViewportOptions')
if (($viewportFields -join ',') -ne 'x,y,zoom') { throw "FAIL viewport fields" }
if (($optionFields -join ',') -ne 'x,y,zoom') { throw "FAIL viewport option fields" }

Assert-Contains $spec 'getViewport\(\): Promise<Viewport>' 'public getter signature'
Assert-Contains $index 'Viewport,' 'public viewport type export'
Assert-Contains $androidSpec 'abstract fun getViewport\(\): Promise<Viewport>' 'generated Android getter'
Assert-Contains $iosSpec 'func getViewport\(\) throws -> Promise<Viewport>' 'generated iOS getter'
Assert-Contains $androidView 'override fun getViewport\(\): Promise<Viewport>' 'Android native getter'
Assert-Contains $iosDocument 'func getViewport\(\) throws -> Promise<Viewport>' 'iOS native getter'
Assert-NotContains $iosDocument '(var|let) currentViewport\s*=' 'iOS has no duplicate viewport state'
Assert-Contains $spec 'x\?: number\s*\r?\n\s*y\?: number\s*\r?\n\s*zoom\?: number' 'options structure'
Assert-Contains $spec 'x: number\s*\r?\n\s*y: number\s*\r?\n\s*zoom: number' 'snapshot structure'

Write-Output "PASS viewport public/generated/native parity checks"
