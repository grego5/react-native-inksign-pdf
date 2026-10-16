[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Read-Source([string]$RelativePath) {
  Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw
}

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Name) {
  if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Name) {
  if ($Text -match $Pattern) { throw "FAIL $Name" }
}

# This Windows gate checks platform ownership. Behavioral coverage runs in XCTest.
$view = Read-Source "ios/ViewerCanvas.swift"
$viewerState = Read-Source "ios/ViewerDocumentState.swift"
$documentCoordinator = Read-Source "ios/DocumentCoordinator.swift"
$documentState = Read-Source "ios/CommittedDocumentState.swift"
$pageTransactions = Read-Source "ios/DocumentCoordinator+PageTransactions.swift"
$export = Read-Source "ios/DocumentCore+Export.swift"
$podspec = Read-Source "ReactNativeInkSignPdf.podspec"

Assert-Contains $documentCoordinator 'let pdfQueue = DispatchQueue' 'one coordinator PDF queue exists'
Assert-NotContains $documentState '\bPDFDocument\b|\bPDFPage\b' 'core state is independent of PDFKit presentation'
Assert-Contains $viewerState 'let document: PDFDocument' 'viewer owns the PDFKit document'
Assert-Contains $viewerState 'activePageID' 'viewer selection uses stable page identity'
Assert-Contains $pageTransactions 'InkSignPdfPdfiumBackend\.assemble\(' 'structural mutation uses the shared PDFium writer'
Assert-Contains $view 'let documentView = PDFView\(\)' 'PDFKit owns iOS presentation'
Assert-Contains $view 'usePageViewController\(true' 'PDFKit owns native page swipe navigation'
Assert-Contains $view 'pageOverlayViewProvider = overlayProvider' 'PDFKit supplies page overlays'
Assert-NotContains $view 'InkPdfView|edgeNavigationGestureRecognizer|PageTurnPreview' 'the live view has no custom presentation engine'
Assert-Contains $export 'InkSignPdfPdfiumExporter\.write\(' 'core finalize calls the native exporter'
Assert-Contains $podspec "'PDFKit'" 'production pod links PDFKit'
Assert-Contains $podspec "'CoreText'" 'production pod links Core Text'

Write-Output "PASS native iOS PDF backend contract checks"
