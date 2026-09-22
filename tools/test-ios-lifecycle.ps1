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
$inputCoordinator = Read-Source "ios/PageInputCoordinator.swift"
$cacheArtifacts = Read-Source "ios/CacheArtifacts.swift"
$export = Read-Source "ios/InkSignView+Export.swift"
$textRendering = Read-Source "ios/TextRendering.swift"
$lifecycleTests = Read-Source "ios/tests/InkSignViewLifecycleTests.swift"
$inputTests = Read-Source "ios/tests/PageInputCoordinatorTests.swift"
$renderingDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/rendering.md"
$lifecycleDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/view-lifecycle.md"
$exportDocs = Read-Source ".agents/skills/inksign-pdf-docs/references/swift-ios/export.md"

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
Assert-Contains $document 'PDFDocument\(url: workingURL\)' 'PDFKit reads the module-owned working source'
Assert-Contains $documentState 'final class InkSignPdfDocumentCoordinator' 'document coordinator owns native document state'
Assert-Contains $documentState 'private\(set\) var generation' 'document coordinator owns generation state'
Assert-Contains $documentState 'activePageID' 'active page is stored by stable identity'
Assert-Contains $documentState 'let workingURL: URL' 'document state retains its working artifact'
Assert-NotContains $view 'var documentState|var generation' 'view keeps no parallel document or generation state'
Assert-Contains $documentState 'func admit\(' 'coordinator admits serialized document operations'
Assert-Contains $documentState 'func settle\(' 'coordinator settles operation artifacts'
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
Assert-Contains $lifecycleDocs 'coordinator owns the published PDFKit document, PDFium session, generation' 'lifecycle reference documents coordinator ownership'

# Page-input staging is a separate lifecycle boundary until Task 6 consumes
# the detached staged values in the structural mutation coordinator.
Assert-Contains $view 'pageInputCoordinator' 'iOS view owns page-input staging'
Assert-Contains $document 'pageInputCoordinator\.cancelPending\(\)' 'open invalidates page-input staging'
Assert-Contains $inputCoordinator 'UIDocumentPickerViewController' 'Files picker exists'
Assert-Contains $inputCoordinator 'PHPickerViewController' 'Photo Library picker exists'
Assert-Contains $inputCoordinator 'allowsMultipleSelection = true' 'Files picker allows multiple selection'
Assert-Contains $inputCoordinator 'selectionLimit = 0' 'Photo picker allows multiple selection'
Assert-Contains $inputCoordinator 'configuration\.selection = \.ordered' 'Photo picker preserves selection order'
Assert-Contains $inputCoordinator 'controllerDismisser\(picker, false\)' 'Photo picker is dismissed before staging'
Assert-Contains $inputCoordinator 'startAccessingSecurityScopedResource' 'Files staging enters security scope'
Assert-Contains $inputCoordinator 'stopAccessingSecurityScopedResource' 'Files staging leaves security scope'
Assert-Contains $inputCoordinator 'coordinate\(\s*readingItemAt:' 'Files staging coordinates provider reads'
Assert-Contains $inputCoordinator 'loadFileRepresentation' 'Photo staging copies provider files'
Assert-Contains $inputCoordinator 'operationInProgress' 'page-input conflicts have stable errors'
Assert-Contains $inputCoordinator 'operationCancelled' 'page-input cancellation has stable errors'
Assert-Contains $cacheArtifacts 'allocateStagedInput' 'iOS cache allocates staged inputs'
Assert-Contains $cacheArtifacts 'stagedInputPattern' 'iOS startup scavenges staged inputs'
Assert-Contains $cacheArtifacts 'allocateWorkingSource' 'iOS cache allocates working sources'
Assert-Contains $cacheArtifacts 'workingSourcePattern' 'iOS startup scavenges working sources'
Assert-Contains $cacheArtifacts 'allocateExportSnapshot' 'iOS cache allocates export snapshots'
Assert-Contains $cacheArtifacts 'exportSnapshotPattern' 'iOS startup scavenges export snapshots'
Assert-Contains $inputCoordinator 'documentPickerFactory' 'picker construction is injectable'
Assert-Contains $inputCoordinator 'sourceChooser' 'Files and Photos routing is injectable'
Assert-Contains $inputCoordinator 'securityScope' 'security scope access is injectable'
Assert-Contains $inputTests 'testPhotoCancellationDismissesPicker' 'photo picker cancellation is tested'
Assert-Contains $inputTests 'testDisposalCancellationRejectsPendingPickerAndDismissesIt' 'picker disposal is tested'
Assert-Contains $inputTests 'testPickerRoutesFilesAndPhotoLibraryWithAllowedTypesAndOrderedPhotos' 'picker routing and allowed types are tested'
Assert-Contains $inputTests 'testConcurrentRequestIsRejectedAndStalePickerCannotSettleNewRequest' 'page-input supersession is tested'
Assert-Contains $inputTests 'testSecurityScopeIsBalancedForEachLocalSource' 'security-scope balance is tested'
Assert-Contains $lifecycleTests 'testCoordinatorUsesStablePageIdentityAndOwnsWorkingArtifact' 'coordinator page identity and working artifact ownership are tested'
Assert-Contains $lifecycleTests 'testCoordinatorAdmissionDirtyAggregationAndArtifactCleanup' 'coordinator admission, dirty aggregation, and cleanup are tested'
Assert-Contains $lifecycleTests 'testStaleExportCannotPublishOutput' 'stale export publication is tested'
Assert-Contains $lifecycleTests 'testFailedReplacementRestoresPublishedDocumentAndDeletesCandidate' 'failed replacement restores document and removes working artifact'
Assert-Contains $export 'sourceSnapshot' 'finalize exports from an immutable source artifact'
Assert-Contains $exportDocs 'unique immutable\s+snapshot artifact' 'export reference documents snapshot ownership'

Write-Output "PASS iOS PDFium rendering contract checks"
