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

$view = Read-Source "ios/InkSignView.swift"
$pageView = Read-Source "ios/PdfPageView.swift"
$preview = Read-Source "ios/PagePreview.swift"
$documentState = Read-Source "ios/DocumentState.swift"
$candidateLoader = Read-Source "ios/DocumentCandidateLoader.swift"
$mutableTransactions = Read-Source "ios/MutableDocumentTransactions.swift"
$inputCoordinator = Read-Source "ios/PageInputCoordinator.swift"
$cacheArtifacts = Read-Source "ios/CacheArtifacts.swift"
$export = Read-Source "ios/InkSignView+Export.swift"
$nativeExporter = Read-Source "ios/NativePDFExporter.swift"
$vectorAnnotation = Read-Source "ios/PDFVectorAnnotation.swift"
$textRendering = Read-Source "ios/TextRendering.swift"
$signaturePath = Read-Source "ios/SignatureVectorPath.swift"
$podspec = Read-Source "ReactNativeInkSignPdf.podspec"
$lifecycleTests = Read-Source "ios/tests/InkSignViewLifecycleTests.swift"
$backendTests = Read-Source "ios/tests/NativePDFBackendTests.swift"
$inputTests = Read-Source "ios/tests/PageInputCoordinatorTests.swift"
$renderingDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/rendering.md"
$lifecycleDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md"
$exportDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/export.md"

# PDFKit owns the published iOS document; the coordinator serializes all PDF work.
Assert-Contains $documentState 'let pdfQueue = DispatchQueue' 'one coordinator PDF queue exists'
Assert-Contains $documentState 'let document: PDFDocument' 'document state owns the PDFKit document'
Assert-Contains $documentState 'let page: PDFPage' 'stable page records retain their PDFKit pages'
Assert-Contains $documentState 'activePageID' 'active page is stored by stable identity'
Assert-Contains $candidateLoader 'PDFDocument\(url: url\)' 'candidate loading uses PDFKit'
Assert-Contains $candidateLoader 'document\.page\(at: index\)' 'candidate records are derived from PDFKit pages'
Assert-Contains $mutableTransactions 'candidate\.insert\(page, at:' 'PDF pages transfer by direct insertion'
Assert-Contains $mutableTransactions 'candidate\.write\(to: allocated\)' 'structural candidates are written before publication'
Assert-Contains $mutableTransactions 'InkSignPdfDocumentCandidateLoader\.load\(url: allocated\)' 'structural candidates are reopened before publication'
Assert-Contains $pageView 'context\.drawPDFPage\(pageRef\)' 'live pages render with Quartz'
Assert-Contains $preview 'baseContext\.drawPDFPage\(pageRef\)' 'page previews render with Quartz'
Assert-Contains $export 'InkSignPdfNativeExporter\.write\(' 'finalize calls the native exporter'
Assert-Contains $nativeExporter 'page\.addAnnotation\(InkSignPdfVectorAnnotation\(' 'export adds editor content as native PDF annotations'
Assert-Contains $nativeExporter 'document\.write\(to: outputURL\)' 'export writes the edited source document'
Assert-Contains $nativeExporter 'annotation\.hasAppearanceStream' 'export verifies persisted annotation appearances'
Assert-Contains $nativeExporter 'PDFDocument\(url: outputURL\)' 'export reopens its written candidate'
Assert-NotContains $nativeExporter 'CGContext\(consumer|drawPDFPage|copyAnnotations|writePageContent' 'export does not reconstruct source pages'
Assert-Contains $vectorAnnotation 'final class InkSignPdfVectorAnnotation: PDFAnnotation' 'editor output uses PDFKit annotations'
Assert-Contains $vectorAnnotation 'lockedContentsFlag' 'text annotations prevent content edits'
Assert-Contains $vectorAnnotation 'override func draw\(with box: PDFDisplayBox, in context: CGContext\)' 'annotation appearance uses vector drawing'
Assert-Contains $textRendering 'CTLineDraw' 'committed text is drawn with Core Text'
Assert-Contains $textRendering 'CTParagraphStyleCreate' 'Core Text receives the text direction'
Assert-Contains $signaturePath 'path\.fillPath|path\.closeSubpath' 'signature output uses filled vector outlines'
Assert-NotContains $export 'InkSignPdfPdfiumSession|PdfiumTextLineSnapshot|InkSnapshot' 'finalize has no PDFium or raster signature model'
Assert-NotContains $podspec 'PDFium|pdfium|xcframework' 'iOS package links no PDFium artifacts'
Assert-Contains $podspec "'PDFKit'" 'production pod links PDFKit'
Assert-Contains $podspec "'CoreText'" 'production pod links Core Text'

$iosTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $root "ios/tests")) + [System.IO.Path]::DirectorySeparatorChar
$iosProductionFiles = Get-ChildItem -LiteralPath (Join-Path $root "ios") -Recurse -File |
  Where-Object {
    -not $_.FullName.StartsWith($iosTestsRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
    @(".swift", ".mm", ".m", ".h") -contains $_.Extension
  }
foreach ($sourceFile in $iosProductionFiles) {
  $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw
  Assert-NotContains $sourceText 'InkSignPdfPdfiumSession|PdfiumRenderSession|FPDF_[A-Za-z0-9_]+' "iOS production has no PDFium bridge ($($sourceFile.Name))"
}

# Picker staging owns external-file access; structural mutation consumes staged values.
Assert-Contains $view 'pageInputCoordinator' 'iOS view owns page-input staging'
Assert-Contains $inputCoordinator 'UIDocumentPickerViewController' 'Files picker exists'
Assert-Contains $inputCoordinator 'PHPickerViewController' 'Photo Library picker exists'
Assert-Contains $inputCoordinator 'allowsMultipleSelection = true' 'Files picker allows multiple selection'
Assert-Contains $inputCoordinator 'selectionLimit = 0' 'Photo picker allows multiple selection'
Assert-Contains $inputCoordinator 'configuration\.selection = \.ordered' 'Photo picker preserves selection order'
Assert-Contains $inputCoordinator 'startAccessingSecurityScopedResource' 'Files staging enters security scope'
Assert-Contains $inputCoordinator 'stopAccessingSecurityScopedResource' 'Files staging leaves security scope'
Assert-Contains $inputCoordinator 'coordinate\(\s*readingItemAt:' 'Files staging coordinates provider reads'
Assert-Contains $inputCoordinator 'loadFileRepresentation' 'Photo staging copies provider files'
Assert-Contains $cacheArtifacts 'allocateStagedInput' 'iOS cache allocates staged inputs'
Assert-Contains $cacheArtifacts 'allocateWorkingSource' 'iOS cache allocates working sources'
Assert-Contains $cacheArtifacts 'allocateExportSnapshot' 'iOS cache allocates immutable export snapshots'
Assert-Contains $inputTests 'testPhotoCancellationDismissesPicker' 'photo picker cancellation is tested'
Assert-Contains $inputTests 'testSecurityScopeIsBalancedForEachLocalSource' 'security-scope balance is tested'
Assert-Contains $lifecycleTests 'testCoordinatorUsesStablePageIdentityAndOwnsWorkingArtifact' 'coordinator identity and artifact ownership are tested'
Assert-Contains $lifecycleTests 'testStaleExportCannotPublishOutput' 'stale export publication is tested'
Assert-Contains $backendTests 'testCrossDocumentInsertionPreservesOrderVisiblePagesAndGeometry' 'native page import contract is tested'
Assert-Contains $backendTests 'testNativeExportAddsLockedTextAndReadOnlyVectorAnnotationsToSourcePages' 'native annotation export contract is tested'

Assert-Contains $renderingDocs 'PDFKit' 'rendering reference documents the native backend'
Assert-Contains $lifecycleDocs 'PDFKit' 'lifecycle reference documents PDFKit ownership'
Assert-Contains $exportDocs 'CoreText' 'export reference documents native text shaping'
Assert-NotContains $exportDocs 'PDFium is the only production' 'export reference has no obsolete PDFium ownership claim'

Write-Output "PASS native iOS PDF backend contract checks"
