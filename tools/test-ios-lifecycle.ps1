[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot

function Read-Source([string]$RelativePath) {
  return Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw
}

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Name) {
  if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Name) {
  if ($Text -cmatch $Pattern) { throw "FAIL $Name" }
}

$view = Read-Source "ios/InkSignView.swift"
$pageView = Read-Source "ios/PdfiumPageView.swift"
$preview = Read-Source "ios/PagePreview.swift"
$overlay = Read-Source "ios/PageOverlay.swift"
$documentState = Read-Source "ios/DocumentState.swift"
$document = Read-Source "ios/InkSignView+Document.swift"
$export = Read-Source "ios/InkSignView+Export.swift"
$textRendering = Read-Source "ios/TextRendering.swift"
$lifecycleTests = Read-Source "ios/tests/InkSignViewLifecycleTests.swift"
$renderingDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/rendering.md"
$lifecycleDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md"

# One PDFium-backed base-page renderer is used for both live tiles and previews.
Assert-Contains $view 'let documentView = InkPdfView\(\)' 'iOS view owns the PDFium page host'
Assert-Contains $pageView 'final class InkPdfView' 'PDFium page host exists'
Assert-Contains $pageView 'private var tileViews' 'page host owns visible tiles'
Assert-Contains $pageView 'try session\.renderPage\(' 'live tiles render through PDFium'
Assert-Contains $preview 'try request\.pdfiumSession\.renderPage\(' 'previews render through PDFium'
Assert-NotContains $view 'PDFView' 'iOS coordinator does not use PDFKit display host'
Assert-NotContains $pageView 'PDFView' 'page host does not use PDFKit display host'
Assert-NotContains $preview 'pageRef\.draw\(|drawPDFPage' 'previews do not draw the source page through Core Graphics'

# PDFKit remains only as source metadata/export support; display state carries
# no compatibility-text snapshot or renderer adapter.
Assert-Contains $document 'let loaded = PDFDocument\(data: sourceData\)' 'PDFKit source document remains available for metadata'
Assert-Contains $export 'drawPDFPage' 'PDFKit/Core Graphics source export remains available'
Assert-NotContains $documentState 'compatibility|CompatibilityText|textRuns' 'page state has no compatibility text model'
Assert-NotContains $preview 'compatibility|CompatibilityText|textRuns' 'preview request has no compatibility text model'
Assert-NotContains $overlay 'compatibility|CompatibilityText|compatibilityTextView' 'overlay has no compatibility text container'
Assert-Contains $overlay 'let canvasView = InkCanvasView\(\)' 'overlay retains only the annotation canvas'
Assert-Contains $lifecycleTests 'InkSignPdfPdfiumSession\(' 'lifecycle fixture opens a PDFium session'
Assert-Contains $lifecycleTests 'pdfiumSession: pdfiumSession' 'lifecycle fixture retains its PDFium session'
Assert-Contains $lifecycleTests 'documentView\.installPage\(' 'lifecycle fixture installs the active PDFium page'
Assert-NotContains $lifecycleTests 'pageOverlayViewProvider|documentView\.document\s*=|overlayProvider\.pdfView\(' 'lifecycle fixture does not use removed PDFKit host APIs'

# The retained overlay is presentation-only; committed text uses the normal
# annotation renderer and is not part of the PDF base-page path.
Assert-Contains $preview 'InkSignPdfTextRenderer\.drawForPreview' 'preview renders committed annotations'
Assert-Contains $textRendering 'enum InkSignPdfTextRenderer' 'committed text has one renderer'
Assert-NotContains $lifecycleTests 'CompatibilityText|compatibilityText|PdfFontOverlayCharacterization' 'lifecycle tests do not exercise retired compatibility paths'

# Static review also verifies the documented ownership contract.
Assert-Contains $renderingDocs 'PDFium pixels are the only base page image' 'rendering reference documents one base renderer'
Assert-Contains $renderingDocs 'Page-turn previews render the target page through the retained PDFium session' 'rendering reference documents PDFium previews'
Assert-Contains $lifecycleDocs 'PDFium supplies page dimensions and all base display pixels' 'lifecycle reference documents PDFium ownership'
Assert-Contains $lifecycleDocs 'PDFKit document remains available only for source metadata and export' 'lifecycle reference limits PDFKit ownership'

Write-Output "PASS iOS PDFium rendering contract checks"
