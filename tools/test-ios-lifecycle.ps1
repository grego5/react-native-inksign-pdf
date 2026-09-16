[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$inputPath = Join-Path $root "ios\InkInput.swift"
$viewPath = Join-Path $root "ios\PdfView.swift"
$previewPath = Join-Path $root "ios\PagePreview.swift"
$documentPaths = @(
    (Join-Path $root "ios\PdfView+Document.swift"),
    (Join-Path $root "ios\PdfView+PageNavigation.swift"),
    (Join-Path $root "ios\PdfView+Viewport.swift"),
    (Join-Path $root "ios\PdfView+Overlay.swift")
)
$lifecyclePath = Join-Path $root "ios\PageNavigationLifecycle.swift"
$overlayPath = Join-Path $root "ios\PageOverlay.swift"
$historyPath = Join-Path $root "ios\History.swift"
$textStatePath = Join-Path $root "ios\TextState.swift"
$textInteractionPath = Join-Path $root "ios\TextInteraction.swift"
$textRenderingPath = Join-Path $root "ios\TextRendering.swift"
$exportPath = Join-Path $root "ios\PdfView+Export.swift"
$policyPath = Join-Path $root "ios\CacheArtifacts.swift"
$startupPath = Join-Path $root "ios\ReactNativeInkSignPdfStartup.m"
$viewportDocsPath = Join-Path $root ".agents\skills\inksign-pdf-docs\references\swift-ios\viewport-input.md"
$exportDocsPath = Join-Path $root ".agents\skills\inksign-pdf-docs\references\swift-ios\export.md"
$validationDocsPath = Join-Path $root ".agents\skills\inksign-pdf-docs\references\swift-ios\configuration-validation.md"
$lifecycleTestsPath = Join-Path $root "ios-tests\PdfViewLifecycleTests.swift"

$input = Get-Content -LiteralPath $inputPath -Raw
$view = Get-Content -LiteralPath $viewPath -Raw
$preview = Get-Content -LiteralPath $previewPath -Raw
$document = ($documentPaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw
$overlay = Get-Content -LiteralPath $overlayPath -Raw
$history = Get-Content -LiteralPath $historyPath -Raw
$textState = Get-Content -LiteralPath $textStatePath -Raw
$textInteraction = Get-Content -LiteralPath $textInteractionPath -Raw
$textRendering = Get-Content -LiteralPath $textRenderingPath -Raw
$export = Get-Content -LiteralPath $exportPath -Raw
$policy = Get-Content -LiteralPath $policyPath -Raw
$startup = Get-Content -LiteralPath $startupPath -Raw
$viewportDocs = Get-Content -LiteralPath $viewportDocsPath -Raw
$exportDocs = Get-Content -LiteralPath $exportDocsPath -Raw
$validationDocs = Get-Content -LiteralPath $validationDocsPath -Raw
$lifecycleTests = Get-Content -LiteralPath $lifecycleTestsPath -Raw

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -notmatch $Pattern) { throw "FAIL $Name" }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Name) {
    if ($Text -match $Pattern) { throw "FAIL $Name" }
}

Assert-Contains $input 'endedDrawingTransactionID' 'ended transaction state exists'
Assert-Contains $input 'endedDrawingBaseline' 'ended transaction baseline exists'
Assert-Contains $input 'func finishEndedDrawingTransaction\(transactionID:' 'ended transaction has one commit path'
Assert-Contains $input 'func canvasViewDidBeginUsingTool\(_ canvasView: PKCanvasView\)' 'PencilKit begin owns lifecycle'
Assert-Contains $input 'func canvasViewDidEndUsingTool\(_ canvasView: PKCanvasView\)' 'PencilKit end owns lifecycle'
Assert-Contains $input 'endedDrawingTransactionID = transactionID' 'tool end transfers ownership'
Assert-Contains $input 'if let transactionID = endedDrawingTransactionID' 'late callback uses ended owner'
Assert-Contains $input 'activeDrawingTransactionID == nil,\s*endedDrawingTransactionID == nil' 'delegate entry rejects overlapping input'
Assert-Contains $input 'guard endedDrawingTransactionID == nil else \{ return nil \}' 'gesture entry rejects ended input'
Assert-Contains $input 'endedDrawingTransactionID = nil\s*\r?\n    endedDrawingBaseline = nil' 'cancellation invalidates ended ownership'
$beginStart = $input.IndexOf('func canvasGestureWillBegin')
$endStart = $input.IndexOf('func canvasDidCancelDrawing')
if ($beginStart -lt 0 -or $endStart -le $beginStart) { throw "FAIL lifecycle callback ordering" }
$beginBody = $input.Substring($beginStart, $endStart - $beginStart)
Assert-NotContains $beginBody 'finishEndedDrawingTransaction' 'new stroke does not flush ended input'
Assert-NotContains $input 'canvasWillBeginDrawing|canvasDidEndDrawing|scheduleDrawingCommit|drawingCommitWorkItem|pendingDrawingEndID|remainingPasses' 'old gesture heuristic removed'
Assert-NotContains $input 'settleDrawingForCommand|finishPendingDrawingTransaction' 'command flush path removed'
Assert-NotContains $overlay 'owner\?\.canvasDidEndDrawing' 'gesture end is not completion proof'
Assert-Contains $overlay 'cancelDrawingInteraction\(\)\s*\r?\n        return' 'rejected overlapping gesture is reset'
Assert-Contains $input 'canvasView\.isInstallingDrawing = true\s*\r?\n    canvasView\.drawing = displayed\s*\r?\n    canvasView\.isInstallingDrawing = false' 'programmatic restore is callback-guarded'
Assert-Contains $history 'cancelActiveStroke\(\)' 'history commands cancel live input'
Assert-NotContains $history 'settleDrawingForCommand' 'history does not force completion'
Assert-Contains $textState 'struct InkSignPdfTextAnnotation' 'iOS canonical text value exists'
Assert-Contains $textRendering 'components\(separatedBy: "\\n"\)' 'text keeps explicit line boundaries'
Assert-Contains $textState 'enum InkSignPdfPageContentActionKind' 'text and ink action kinds share one history'
Assert-Contains $textState 'final class InkSignPdfPageContentHistory' 'page content history has one owner'
Assert-Contains $textState 'func appendText\(_ annotation:' 'text creation is a page-content action'
Assert-Contains $textState 'func replaceText\(' 'text replacement actions are coalescible'
Assert-Contains $textState 'func removeText\(_ annotation:' 'text removal is a page-content action'
Assert-Contains $textState 'func clear\(\)' 'page-content clear is one action'
Assert-Contains $textInteraction 'final class InkSignPdfTextInteractionOverlay' 'iOS text interaction has one transient owner'
Assert-Contains $textInteraction 'private var editor: UITextView\?' 'iOS text editor is transient'
Assert-Contains $textInteraction 'armPlacement\(generation:' 'iOS text placement has a generation-bound arm path'
Assert-Contains $textInteraction 'cancelPendingPlacement\(\)' 'iOS text placement has an idempotent cancel path'
Assert-Contains $textInteraction 'case placing\(PlacementState\)' 'iOS placement shares the interaction state owner'
Assert-NotContains $textInteraction 'private var pendingPlacement:' 'iOS placement has no parallel state field'
Assert-Contains $textInteraction 'placeTextAt\(' 'iOS text placement creates the editor at a tap'
Assert-Contains $textInteraction 'shouldBeRequiredToFailBy otherGestureRecognizer:' 'text gestures take priority over ancestor PDF gestures'
Assert-NotContains $textInteraction 'viewportPanRecognizer' 'PDFKit owns native viewport panning'
Assert-Contains $textInteraction 'placementTapRecognizer' 'iOS placement owns one native tap recognizer'
Assert-Contains $textInteraction 'recognizer\.cancelsTouchesInView = true' 'iOS placement consumes its accepted touch sequence'
Assert-Contains $document 'recognizer\.require\(toFail: placement\)' 'PDF navigation waits for armed text placement'
Assert-Contains $textInteraction 'canonicalPagePoint\(fromOverlay:' 'iOS text placement uses coordinator conversion'
Assert-Contains $textInteraction 'owner\?\.allocateTextAnnotationID\(\)' 'iOS text creation allocates a unique identity'
Assert-NotContains $textInteraction 'text-\(UUID\(\)\.uuidString\)' 'iOS text identity is not a broken UUID literal'
Assert-Contains $textInteraction 'func increaseTextSize\(\) throws' 'iOS increase command targets selection'
Assert-Contains $textInteraction 'func decreaseTextSize\(\) throws' 'iOS decrease command targets selection'
Assert-Contains $textInteraction 'func removeTextAnnotation\(\) throws' 'iOS remove command targets selection'
Assert-Contains $textInteraction 'func finishForLifecycle\(\)' 'iOS text lifecycle has one finish path'
Assert-Contains $textInteraction 'textViewDidEndEditing' 'UIKit editor owns editing completion callback'
Assert-Contains $textInteraction 'UILongPressGestureRecognizer' 'iOS text drag uses native gesture routing'
Assert-Contains $textInteraction 'textFontSizeStep' 'iOS text font range has one step'
Assert-Contains $textInteraction 'minimumTextFontSize: CGFloat = 8' 'iOS text font range has shared minimum'
Assert-Contains $textInteraction 'maximumTextFontSize: CGFloat = 72' 'iOS text font range has shared maximum'
Assert-Contains $textInteraction 'min\(max\(value, Double\(minimumTextFontSize\)\)' 'iOS default text font size clamps valid values'
Assert-Contains $textInteraction 'activeTextAnnotations\(\)\.reversed\(\)' 'iOS hit testing follows page stacking order'
Assert-Contains $textInteraction 'TextError\.notFocused' 'iOS text commands reject missing selection'
Assert-Contains $textInteraction 'InkSignPdfTextRenderer\.drawCanonical' 'live committed text uses the shared renderer'
Assert-NotContains $textInteraction 'addTextAnnotation' 'centered iOS text creation is removed'
Assert-Contains $textRendering 'enum InkSignPdfTextRenderer' 'iOS committed text has one rendering owner'
Assert-Contains $textRendering 'import CoreText' 'iOS text rendering uses Core Text shaping'
Assert-Contains $textRendering 'textMatrix = CGAffineTransform\(scaleX: 1, y: -1\)' 'Core Text compensates for canonical top-left coordinates'
Assert-Contains $textRendering 'components\(separatedBy: "\\n"\)' 'iOS text rendering preserves explicit lines'
Assert-Contains $textRendering 'CTLineCreateWithAttributedString' 'iOS text rendering shapes each line with Core Text'
Assert-Contains $textRendering 'drawForPreview' 'iOS preview text rendering has a worker-safe entry point'
Assert-Contains $textRendering 'drawForPDF' 'iOS export text rendering has a worker-safe entry point'
Assert-Contains $textRendering 'canonicalToPDFTransform' 'iOS text export uses canonical PDF coordinates'
Assert-Contains $textRendering 'format\.opaque = false' 'iOS text fallback is transparent'
Assert-Contains $textRendering 'exportPixelsPerPageUnit' 'iOS text fallback has fixed canonical resolution'
Assert-Contains $textState 'InkSignPdfTextRenderer\.intrinsicSize' 'iOS committed and transient text share renderer metrics'
Assert-Contains $view 'var defaultTextFontSize: Double\?' 'iOS text font prop is stored'
Assert-Contains $view 'var onStateChange: \(\(StateChangeEvent\) -> Void\)\?' 'iOS coarse interaction state callback exists'
Assert-NotContains $view 'onTextFocusChange|TextFocusChangeEvent' 'iOS exposes no parallel text focus callback'
Assert-Contains $view 'textInteractionOverlay\.dispose\(\)' 'iOS text owner is disposed'
Assert-Contains $document 'textInteractionOverlay\.finishForLifecycle\(\)' 'iOS page/mode lifecycle finishes text interaction'
Assert-Contains $document 'canvasView\.isUserInteractionEnabled = documentState != nil' 'iOS text routing remains available in view mode'
Assert-Contains $overlay 'if owner\?\.editMode == false, hit === self' 'iOS view-mode text hit testing does not consume PDF navigation'

Assert-NotContains $view 'var mode\s*:' 'mode prop authority removed'
Assert-Contains $document 'func enterEditMode\(viewport: ViewportOptions\?\)' 'edit command exists'
Assert-Contains $document 'func enterViewMode\(viewport: ViewportOptions\?\)' 'view command exists'
Assert-Contains $document 'func getViewport\(\) throws -> Promise<Viewport>' 'viewport snapshot command exists'
Assert-Contains $document 'func currentViewportSnapshot\(\) throws -> Viewport' 'viewport snapshot capture exists'
Assert-Contains $document 'documentView\.convert\(viewCenter, to: page\)' 'viewport uses PDFKit page conversion'
Assert-Contains $document 'let zoom = Double\(documentView\.scaleFactor\)' 'viewport returns PDFKit scale'
Assert-Contains $document 'throw ViewportError\.cancelled' 'viewport capture checks deferred generation'
Assert-Contains $document 'case \.fit' 'empty viewport fit path exists'
Assert-Contains $document 'scaleFactorForSizeToFit' 'fit uses PDFKit content bounds'
Assert-Contains $view 'struct PendingOpen' 'open readiness has one transaction owner'
Assert-Contains $view 'var pendingOpen: PendingOpen\?' 'open promise is generation-bound'
Assert-Contains $document 'tryApplyPendingOpenViewport' 'initial viewport has deferred layout retry'
Assert-Contains $document 'tryCompletePendingOpen' 'open resolves through readiness completion'
Assert-Contains $document 'try requireViewportReady\(request: pending\.fitToPage \? \.fit : \.preserve\)' 'open shares command readiness predicate'
Assert-Contains $document 'pendingOpen\?\.token == token' 'stale load callbacks cannot resolve open'
Assert-Contains $document 'attachedOverlayPage === state\.activePage\.page' 'open waits for active overlay identity'
Assert-Contains $document 'overlayTransformPage === state\.activePage\.page' 'open waits for active transform identity'
Assert-Contains $document 'pageToOverlayTransform != nil' 'open waits for valid transform'
Assert-NotContains $view 'pendingInitialFitGeneration|pendingLoad' 'old split open readiness state removed'
Assert-Contains $document 'usableFitScale' 'fit rejects unusable layout without minimum fallback'
Assert-Contains $document 'pendingOpen = nil' 'open clears on replacement and failure'
Assert-Contains $document 'x and y must be supplied together' 'paired focus validation exists'
Assert-Contains $document 'func setInteractionMode\(editing: Bool\)' 'native mode installation exists'
Assert-Contains $document 'setInteractionMode\(editing: false\)' 'open defaults to view mode'
Assert-Contains $document 'completion: self\.programmaticPageSwitchCompletion\(promise: promise\)' 'programmatic navigation uses the owned completion factory'
Assert-Contains $document '\{ \[weak self\] result in' 'programmatic page completion is weakly captured'
Assert-Contains $document 'let tappedPoint = canonicalPoint\(from: pdfPoint\)' 'double tap captures canonical tap point'
Assert-Contains $document 'let focus = clampedViewportFocus\(tappedPoint, at: clampedTargetZoom\)' 'double tap centers tapped canonical focus'
Assert-Contains $document 'private func clampedViewportFocus\(_ point: CGPoint, at zoom: CGFloat\)' 'double tap clamps target focus to viewport bounds'
Assert-NotContains $document 'magnification|savedFocus|visited|pendingPageSwitchFocus' 'page switch has no shared or saved viewport state'
Assert-Contains $document 'fitToPage: true' 'page switch applies fit-centered target viewport'
Assert-Contains $document 'let rotation = \(\(pageGeometry\.rotation % 360\) \+ 360\) % 360' 'double tap accounts for page rotation'
Assert-NotContains $document 'zoomRatio = currentZoom / clampedTargetZoom' 'double tap does not preserve finger anchor'
Assert-Contains $document 'let viewPrecision = max\(0\.5' 'fit detection uses visible precision'
Assert-Contains $document 'let scaleTolerance = viewPrecision / pageExtent' 'fit scale tolerance is view-derived'
Assert-Contains $document 'let pageCenterInView = documentView\.convert' 'fit center is measured in view coordinates'
Assert-Contains $document 'centerDistance <= viewPrecision' 'fit center uses view-space tolerance'
Assert-Contains $overlay 'weak var owner: PdfView\?' 'PDF view has weak coordinator owner'
Assert-Contains $view 'documentView\.owner = self' 'PDF view installs coordinator owner'
Assert-Contains $overlay 'override func hitTest\(_ point: CGPoint, with event: UIEvent\?\) -> UIView\?' 'PDF view observes pre-dispatch hit testing'
Assert-Contains $overlay 'event\?\.allTouches\?\.contains\(where: \{ \$0\.phase == \.began \}\) == true' 'hit testing filters newly beginning touches'
Assert-Contains $overlay 'owner\?\.documentViewNavigationTouchBegan\(self\)' 'navigation touch notifies coordinator'
Assert-NotContains $overlay 'override func touchesBegan' 'unreliable touch override is absent'
Assert-Contains $document 'func documentViewNavigationTouchBegan\(_: InkPdfView\)' 'coordinator receives navigation touch notification'
Assert-Contains $document 'func documentViewNavigationTouchBegan\(_: InkPdfView\)\s*\{\s*pageTurnLifecycle\.cancelSettlement\(\)\s*\r?\n\s*cancelViewportAnimation\(\)' 'navigation touch cancels viewport and page-turn animation'
$hitTestStart = $overlay.IndexOf('override func hitTest')
$beganCheck = $overlay.IndexOf('event?.allTouches?.contains(where: { $0.phase == .began }) == true', $hitTestStart)
$touchNotify = $overlay.IndexOf('owner?.documentViewNavigationTouchBegan(self)', $hitTestStart)
$hitTestSuper = $overlay.IndexOf('super.hitTest(point, with: event)', $hitTestStart)
if ($hitTestStart -lt 0 -or $beganCheck -lt $hitTestStart -or
    $touchNotify -le $beganCheck -or $hitTestSuper -le $touchNotify) {
    throw "FAIL pre-dispatch navigation touch cancellation ordering"
}
Assert-Contains $document 'let request = try Self\.parseViewport\(viewport\)' 'mode request validates options'
Assert-Contains $document 'try self\.requireViewportReady\(request: request\)' 'mode request validates readiness'
Assert-Contains $document 'self\.viewportRequestID &\+= 1' 'mode request is accepted after validation'
Assert-Contains $view 'UIGestureRecognizerDelegate' 'edge recognizer delegate is coordinator-owned'
Assert-Contains $view 'edgeNavigationGestureRecognizer' 'edge recognizer is retained by the coordinator'
Assert-Contains $document 'func handleEdgeNavigationPan\(_ recognizer: UIPanGestureRecognizer\)' 'edge recognizer has one coordinator action'
Assert-Contains $document 'func beginPageTurnCommit\(targetPageIndex: Int\)' 'page-turn commit passes captured target identity'
Assert-Contains $document 'shouldReceive touch: UITouch' 'edge eligibility captures at touch begin'
Assert-Contains $document 'func prepareForEdgeNavigationTouch\(at location: CGPoint\)' 'edge eligibility has a directly testable preflight'
Assert-Contains $document 'return prepareForEdgeNavigationTouch\(at: touch\.location\(in: documentView\)\)' 'UIKit delegate routes through preflight'
Assert-Contains $document 'pageTurnLifecycle\.pullChanged\(translation:' 'UIKit adapter forwards translated pull updates'
Assert-Contains $document 'pageTurnLifecycle\.pullEnded\(\)' 'UIKit adapter forwards pull release'
Assert-Contains $document 'pageTurnLifecycle\.pullCancelled\(\)' 'UIKit adapter forwards pull cancellation'
Assert-Contains $document 'shouldRecognizeSimultaneouslyWith otherGestureRecognizer' 'edge recognizer preserves PDFView gestures'
Assert-Contains $lifecycle 'func captureGesture\(at location: CGPoint\)' 'edge recognizer uses PDFKit conversion geometry'
Assert-Contains $document 'edgeNavigationGestureRecognizer\.isEnabled = !editing' 'edge recognizer follows interaction mode'
Assert-Contains $lifecycle 'deadZone: 8' 'edge recognizer has an 8-point dead zone'
Assert-Contains $lifecycle 'visiblePageWidth \* 0\.30' 'edge recognizer derives arm distance from visible page width'
Assert-Contains $lifecycle 'let resisted = min\(40' 'edge recognizer applies resistant presentation'
Assert-Contains $lifecycle 'progress >= 1' 'edge recognizer commits only after release while armed'
Assert-Contains $lifecycle 'hapticIssued' 'edge recognizer limits haptics per gesture'
Assert-Contains $lifecycle 'showPreview' 'edge recognizer drives the target preview'
Assert-Contains $lifecycle 'location\.x >= pageBounds\.minX - edgeTolerance' 'edge recognizer accepts any in-page touch'
Assert-NotContains $lifecycle 'touchesLeftEdge|touchesRightEdge' 'edge recognizer has no screen-edge touch gate'
Assert-Contains $lifecycle 'isRTL \? atRight : atLeft' 'edge recognizer maps RTL previous eligibility'
Assert-Contains $lifecycle 'isRTL \? atLeft : atRight' 'edge recognizer maps RTL next eligibility'
Assert-Contains $lifecycle 'abs\(translation\.x\) > abs\(translation\.y\)' 'edge recognizer requires horizontal dominance'
Assert-Contains $lifecycle 'pageSwitchStarted' 'page-switch handoff owns preview direction'
Assert-Contains $document 'documentView\.currentPage === state\.activePage\.page' 'page-switch handoff validates target page identity'
Assert-Contains $document 'let fitScale = usableFitScale\(\)' 'page-switch handoff waits for usable target geometry'
Assert-NotContains $document 'usableFitScale\(\) \?\? 0\.1' 'page switch has no unavailable-fit fallback'
Assert-Contains $document 'cancelPendingPageSwitch\(\)' 'page-switch intent has one cancellation path'
Assert-Contains $lifecycle 'reconcilePreviews' 'previews are reconciled from stable layout'
Assert-Contains $lifecycle 'previewView\.install' 'preview installs a static target snapshot'
Assert-Contains $lifecycle 'targetContentRevision' 'preview identity includes committed page-content revision'
Assert-Contains $lifecycle 'textAnnotations: target.history.content.textAnnotations' 'preview snapshot carries committed text'
Assert-Contains $lifecycle 'pageTurnTargetDelta' 'gesture and preview share physical-direction mapping'
Assert-Contains $lifecycle 'isRTL: isRTL' 'preview identity captures layout direction'
Assert-Contains $lifecycle 'InkSignPdfDispatchPreviewScheduler' 'production preview scheduling uses a serial worker adapter'
Assert-Contains $lifecycle 'previewScheduler\.schedule' 'lifecycle submits previews through an injected scheduler'
Assert-Contains $lifecycle 'animationDriverFactory\.make' 'lifecycle creates settlement drivers through an injected factory'
Assert-Contains $lifecycle 'func pullChanged\(translation: CGPoint\)' 'lifecycle exposes a production pull update event'
Assert-Contains $lifecycle 'func pullEnded\(\)' 'lifecycle exposes a production pull release event'
Assert-Contains $lifecycle 'func pullCancelled\(\)' 'lifecycle exposes a production pull cancellation event'
Assert-Contains $lifecycle 'PreviewSlot' 'preview worker ownership is direction-local'
Assert-Contains $lifecycle 'enum TurnState' 'turn transaction has one four-state owner'
Assert-Contains $lifecycle 'case idle\s*\r?\n\s*case pulling\(PullTransaction\)\s*\r?\n\s*case settling\(SettlementTransaction\)\s*\r?\n\s*case committed\(CommittedHandoff\)' 'turn state has exactly four states'
Assert-Contains $lifecycle 'var previewSlots' 'preview readiness is independent from turn state'
Assert-NotContains $lifecycle 'enum Phase|PreparingState|ReadyState|CommittingState|WaitingForLiveTargetState|isCompatibleActiveContext' 'old combined phase model is removed'
Assert-Contains $lifecycle 'var newRequests = ' 'preview reconciliation tracks new worker identities'
Assert-Contains $lifecycle 'for \(direction, rendering\) in newRequests' 'preview reconciliation submits only new requests'
Assert-Contains $lifecycle 'current\.request\.key == request\.key' 'stale preview worker results are rejected'
Assert-Contains $lifecycle 'expected\.key == request\.key' 'preview installation revalidates full layout identity'
Assert-Contains $lifecycle 'current\.instance == instance' 'stale same-key preview worker results are rejected'
Assert-Contains $lifecycle 'let instance: UInt64' 'preview submissions carry request-instance identity'
Assert-NotContains $view 'pageTurnPreviewPreparationToken\s*[:=]|pageTurnPreviewRequests\s*[:=]|pageTurnPreviews\s*[:=]|pageTurnPreviewInFlight\s*[:=]' 'preview state is not mirrored on the view'
Assert-Contains $lifecycle 'SettlementTransaction' 'page-turn preview owns settlement state'
Assert-Contains $lifecycle 'let token: UUID' 'page-turn snap-back owns non-retaining identity token'
Assert-Contains $lifecycle 'active\.token == token' 'page-turn snap-back rejects stale callbacks'
Assert-NotContains $lifecycle 'self\.settlementDriver === driver' 'page-turn snap-back does not capture its owner'
Assert-Contains $lifecycle 'cancelSettlement\(\)' 'page-turn snap-back has cancellation path'
Assert-Contains $lifecycle 'if case \.settling' 'new touch cancels settlement before eligibility capture'
Assert-Contains $lifecycle 'case \.pulling\(let transaction\)' 'stable context changes settle an active pull'
Assert-Contains $lifecycle 'currentStableContext\(\)' 'active pull identity is context-bound'
Assert-Contains $lifecycle 'stableContextChanged' 'stable lifecycle events use explicit reconciliation'
Assert-Contains $lifecycle 'if case \.committed = phase' 'committed overlay detachment preserves readiness'
Assert-Contains $lifecycle 'owner\.beginPageTurnCommit\(targetPageIndex: targetPageIndex\)' 'committed handoff invokes the exact target once'
Assert-Contains $lifecycle 'func pageSwitchFailed\(switchID: UInt64\)' 'page-switch failure requires its switch identity'
Assert-Contains $lifecycle 'func pageTurnCommitFailedBeforeStart' 'pre-start commit failure has an explicit event'
Assert-Contains $lifecycle 'let reversed = transaction\.physicalDirection != nil' 'reversal invalidates the active pull'
Assert-Contains $lifecycle 'transaction\.presentationOffset != 0' 'active pull cancellation includes presentation state'
Assert-Contains $preview 'InkSignPdfPageTurnPreviewKey' 'page-turn preview has an identity key'
Assert-Contains $preview 'static func render' 'page-turn preview renders a static image'
Assert-Contains $preview 'drawing\.image' 'page-turn preview includes committed ink'
Assert-Contains $preview 'UIGraphicsImageRenderer\(size: size, format: format\)' 'preview renders at fitted logical size'
Assert-Contains $preview 'format\.scale = max\(request\.key\.density, 1\)' 'preview applies output density once'
Assert-Contains $preview 'getDrawingTransform' 'preview maps the rotated media box explicitly'
Assert-Contains $preview 'canonicalToPDF' 'preview maps canonical zero-origin ink explicitly'
Assert-Contains $preview 'InkSignPdfTextRenderer\.drawForPreview' 'preview draws committed text without UI presentation'
Assert-Contains $preview 'context\.cgContext\.drawPDFPage\(pageRef\)' 'preview draws the worker-owned PDF page through CGContext'
Assert-NotContains $preview 'pageRef\.draw\(' 'preview avoids the invalid inverse PDF drawing call'
Assert-NotContains $preview 'pixelSize|size\.width \* scale|size\.height \* scale' 'preview does not multiply logical size before renderer scale'
Assert-Contains $view 'weak var attachedOverlayPage: PDFPage\?' 'overlay attachment identity is coordinator-owned'
Assert-Contains $document 'attachedOverlayPage = page' 'only display callback records overlay owner'
Assert-Contains $document 'attachedOverlayPage === state\.activePage\.page' 'page switch readiness requires target overlay identity'
Assert-Contains $document 'attachedOverlayPage === page' 'overlay refresh and detach use page identity'
Assert-NotContains $document 'canvasView\.superview != nil' 'overlay superview is not readiness authority'
Assert-NotContains $document 'let startPoint: CGPoint' 'edge gesture has no unused start point'
$displayIndex = $document.IndexOf('attachedOverlayPage = page')
$refreshIndex = $document.IndexOf('refreshOverlayTransform(overlay, for: page)', $displayIndex)
if ($displayIndex -lt 0 -or $refreshIndex -le $displayIndex) {
    throw "FAIL overlay attachment is recorded before transform refresh"
}

$captureIndex = $export.IndexOf('captureExportSnapshot()')
$promiseIndex = $export.IndexOf('Promise.parallel')
if ($captureIndex -lt 0 -or $promiseIndex -lt 0 -or $captureIndex -gt $promiseIndex) {
    throw "FAIL export capture precedes worker scheduling"
}
Assert-Contains $export 'struct ExportSnapshot' 'export snapshot type exists'
Assert-Contains $export 'let source: URL\s*\r?\n  let output: URL\s*\r?\n  let pages: \[ExportPageSnapshot\]\s*\r?\n  let generation: UInt64' 'export snapshot binds all page request fields'
Assert-NotContains $export 'let pageCount: Int' 'export snapshot derives count from pages'
Assert-NotContains $export 'settleDrawingForCommand|DispatchGroup|DispatchQueue\.main\.async' 'export has no settlement or queue delay'
Assert-Contains $export 'PKDrawing\(data: page.history.content.drawing.dataRepresentation\(\)\)' 'export copies every committed page drawing'
Assert-Contains $export 'textAnnotations: page.history.content.textAnnotations' 'export snapshot carries committed text'
Assert-Contains $export 'InkSignPdfTextRenderer\.drawForPDF' 'export draws committed text from immutable snapshot'
Assert-NotContains $export 'UITextView|InkSignPdfTextInteractionOverlay|UIView' 'export does not cross with UIKit text presentation'
Assert-Contains $export 'drawing: drawing' 'export page snapshot stores copied committed drawing'
Assert-Contains $export 'sourceDocument\.numberOfPages == pages\.count' 'export validates captured page count'
Assert-Contains $export 'for captured in pages' 'export rewrites every captured page'
Assert-Contains $export 'verifiedDocument\.pageCount == pages\.count' 'export verifies output page count'
Assert-Contains $export 'boxesMatch\(verifiedPage\.bounds\(for: \.mediaBox\), captured\.geometry\.mediaBox\)' 'export verifies each page media box'
Assert-Contains $export 'return Promise\.rejected\(withError: error\)' 'capture failure returns rejected promise'
Assert-Contains $export 'owner\.generation == snapshot\.generation' 'publication checks generation'
Assert-Contains $export 'artifactPolicy\.allocateSignedOutput\(\)' 'export allocates a managed result'
Assert-Contains $export 'pendingOutputURLs' 'export tracks pending output ownership'
Assert-Contains $export 'ownedOutputURLs' 'export tracks published output ownership'
Assert-Contains $export 'artifactPolicy\.deleteExact' 'export uses policy-owned cleanup'
Assert-Contains $export 'throw ExportError\.failed' 'signed-output cache allocation maps to export failure'
Assert-Contains $export 'normalizeExportError' 'worker cache and publication failures are normalized'
Assert-Contains $export 'if let exportError = error as\? ExportError' 'existing public export errors are preserved'
Assert-Contains $export 'allocateExportScratch' 'export scratch allocation remains request-local'
Assert-Contains $export 'allocateVerificationScratch' 'verification scratch allocation remains request-local'
Assert-Contains $export 'defer \{ policy\.deleteExact\(output\) \}' 'export scratch has defer cleanup'
Assert-Contains $export 'if !verifiedSucceeded \{ policy\.deleteExact\(verified\) \}' 'verification scratch has failure cleanup'
Assert-NotContains $export 'managedSourceURL|sourceLifetime|sourceLease|removeManagedSource' 'managed source machinery removed'
Assert-NotContains $document 'managedSourceURL|sourceLifetime|sourceLease|removeManagedSource' 'document source cleanup removed'
Assert-NotContains $view 'managedSourceURL|sourceLifetime|sourceLease|managedSourceLifetimes' 'view source cleanup removed'
Assert-Contains $view 'artifactPolicy' 'view owns immutable artifact policy'
Assert-Contains $view 'exportQueue\.async' 'disposal retires outputs off the main thread'
Assert-Contains $policy 'static let shared' 'artifact policy is process-wide'
Assert-Contains $policy 'ReactNativeInkSignPdfCacheDirectoryName' 'Info.plist override is read'
Assert-Contains $policy 'contentsOfDirectory' 'startup scan is direct-directory based'
Assert-Contains $policy 'signedOutputPattern|exportScratchPattern|verificationScratchPattern' 'known iOS artifacts are classified'
Assert-NotContains $policy 'skipsHiddenFiles' 'hidden scratch files are scanned'
Assert-Contains $startup 'constructor' 'startup hook runs at image initialization'

Assert-Contains $viewportDocs 'ended-state gate' 'lifecycle documentation is current'
Assert-Contains $viewportDocs 'does not infer completion from main-queue timing' 'documentation rejects timing heuristic'
Assert-Contains $exportDocs 'before worker scheduling' 'export boundary is documented'
Assert-Contains $exportDocs 'read-only' 'export isolation is documented'
Assert-Contains $exportDocs 'does not consume' 'non-consuming export is documented'

Assert-Contains $document 'viewportReadiness\(\)\.allowsCommand' 'commands use the shared production readiness policy'
Assert-Contains $lifecycleTests 'testOpenReadinessRequiresTheSameConditionsAsViewportCommands' 'XCTest covers production readiness policy'
Assert-Contains $lifecycleTests 'testProgrammaticPageSwitchCompletionDoesNotRetainView' 'XCTest covers production weak completion ownership'
Assert-Contains $lifecycleTests 'testPageTurnGestureArmsMapsDirectionAndIssuesOneHaptic' 'XCTest covers page-turn arming and haptic state'
Assert-Contains $lifecycleTests 'testPageTurnGestureCancellationReturnsPresentationToRest' 'XCTest covers page-turn cancellation presentation state'
Assert-Contains $lifecycleTests 'testPageTurnGestureMapsBothDirectionsInRTLAndLTR' 'XCTest covers RTL and LTR direction mapping'
Assert-Contains $lifecycleTests 'testPageTurnLifecycleKeepsGestureDataInsidePullingPhase' 'XCTest covers lifecycle phase ownership'
Assert-Contains $lifecycleTests 'testStableContextReconciliationPreservesPullAndSettlementStates' 'XCTest covers stable callback state preservation'
Assert-Contains $lifecycleTests 'testSinglePageLifecycleDoesNotCreatePreviewState' 'XCTest covers single-page preview absence'
Assert-Contains $lifecycleTests 'testTouchPreflightAcceptsOneReadyEligibleDirection' 'XCTest covers independent direction readiness at touch preflight'
Assert-Contains $lifecycleTests 'testRTLPreviewAndCommitUseTheNextPage' 'XCTest covers RTL preview and committed target identity'
Assert-Contains $lifecycleTests 'testRepeatedStablePreviewReconciliationSubmitsOneRenderPerDirection' 'XCTest covers direction-local in-flight reuse'
Assert-Contains $lifecycleTests 'testTwoEligibleDirectionsEachRetainOneInFlightRequest' 'XCTest covers independent physical-direction requests'
Assert-Contains $lifecycleTests 'TestPreviewScheduler' 'XCTest controls preview worker scheduling deterministically'
Assert-Contains $lifecycleTests 'TestAnimationDriverFactory' 'XCTest controls settlement animation deterministically'
Assert-Contains $lifecycleTests 'TestAnimationCallbackHandle' 'XCTest retains delayed animation callbacks without drivers'
Assert-Contains $lifecycleTests 'testChangingOnePreviewIdentityResubmitsOnlyThatDirection' 'XCTest covers direction-local invalidation'
Assert-Contains $lifecycleTests 'testStalePreviewCompletionCannotClearNewerRequestAndFailureCanRetry' 'XCTest covers stale completion and retry ownership'
Assert-Contains $lifecycleTests 'testStaleSameKeyPreviewCompletionCannotClearReplacementRequest' 'XCTest covers stale same-key completion ownership'
Assert-Contains $lifecycleTests 'testDisposalRejectsDelayedPreviewCompletion' 'XCTest covers delayed preview teardown'
Assert-Contains $lifecycleTests 'testDocumentReplacementRejectsDelayedPreviewCompletion' 'XCTest covers replacement preview teardown'
Assert-Contains $lifecycleTests 'testArmedPageTurnChangesPageExactlyOnce' 'XCTest covers one page change after an armed release'
Assert-Contains $lifecycleTests 'testPageTurnPreviewUsesFitCenteredTargetFrame' 'XCTest covers fit-centered preview frame'
Assert-Contains $lifecycleTests 'testTextRendererShapesMultilineLatinAndRTLInCanonicalPreviewSpace' 'XCTest covers preview Unicode and canonical placement'
Assert-Contains $lifecycleTests 'testTextRendererWritesExtractableTextToPDFContext' 'XCTest covers selectable PDF text output'
Assert-Contains $lifecycleTests 'testPageTurnScaleChangesOnlyDuringLatePull' 'XCTest covers smooth late pull scaling'
Assert-Contains $lifecycleTests 'testSubthresholdPageTurnSettlesPreviewWithPageBeforeClearing' 'XCTest covers iOS preview snap-back'
Assert-Contains $lifecycleTests 'testRetreatBelowDeadZoneUsesIdentityCheckedRestSettlement' 'XCTest covers dead-zone retreat settlement'
Assert-Contains $lifecycleTests 'testReversalAndLossOfHorizontalDominanceUseRestSettlement' 'XCTest covers reversal and dominance cancellation'
Assert-Contains $lifecycleTests 'testNewGestureCancelsStalePageTurnSettlement' 'XCTest covers stale new-gesture settlement'
Assert-Contains $lifecycleTests 'testModeChangeCancelsPageTurnSettlementBeforeStaleCallback' 'XCTest covers mode settlement cancellation'
Assert-Contains $lifecycleTests 'testDisposalCancelsPageTurnSettlementBeforeStaleCallback' 'XCTest covers disposal settlement cancellation'
Assert-Contains $lifecycleTests 'testCompletedSettlementDriverIsReleased' 'XCTest covers completed settlement release'
Assert-Contains $lifecycleTests 'testCancelledSettlementDriverIsReleased' 'XCTest covers cancelled settlement release'
Assert-Contains $lifecycleTests 'testTextPlacementOnAndOffAreIdempotent' 'XCTest covers idempotent placement commands'
Assert-Contains $lifecycleTests 'testTextPlacementConsumesOneRoutedTap' 'XCTest covers one-shot placement state routing'
Assert-Contains $lifecycleTests 'testTextPlacementOutsideTapUsesTransformedEditorCoordinates' 'XCTest covers transformed editor hit testing'
Assert-Contains $lifecycleTests 'testTextPlacementOutsideTapDiscardsEmptyDraft' 'XCTest covers empty-draft outside settlement'
Assert-Contains $lifecycleTests 'testTextPlacementOutsideTapCommitsNonEmptyDraft' 'XCTest covers committed outside settlement'
Assert-Contains $lifecycleTests 'testTextPlacementCancelsOnModeAndPageChange' 'XCTest covers mode and page cancellation'
Assert-Contains $lifecycleTests 'testTextPlacementCancelsOnDocumentReplacementAndDisposal' 'XCTest covers replacement and disposal cancellation'
Assert-Contains $lifecycleTests 'testTextPlacementUsesCanonicalZoomedPanCoordinate' 'XCTest covers zoom and pan coordinate placement'
Assert-NotContains $lifecycleTests 'Thread\.sleep|RunLoop\.main\.run|wait\(|drainPreviewQueue|setGestureForTesting|installPreparedPreviewForTesting' 'XCTest has no timing or mutation helpers'
Assert-NotContains $lifecycleTests 'phase\s*=' 'XCTest does not assign lifecycle phases'
Assert-Contains $validationDocs 'non-retaining settlement ownership' 'iOS settlement ownership is documented'
Assert-Contains $lifecycleTests 'testPageSwitchWaitsForOverlayHandoffBeforeCompleting' 'XCTest covers pending page-switch handoff'
Assert-Contains $lifecycleTests 'testCommittedOverlayDetachmentPreservesSnapshotAndSwitchIdentity' 'XCTest covers delayed committed-overlay readiness'
Assert-Contains $lifecycleTests 'testStaleSwitchIDsCannotCompleteCommittedHandoff' 'XCTest covers exact switch identity validation'
Assert-Contains $lifecycleTests 'testPendingPageSwitchCancellationIsExactlyOnceAgainstDelayedCallback' 'XCTest covers delayed switch cancellation'
Assert-Contains $lifecycleTests 'testDocumentReplacementCancelsPendingPageSwitchExactlyOnce' 'XCTest covers replacement cancellation'
Assert-Contains $lifecycleTests 'testDisposalCancelsPendingPageSwitchExactlyOnce' 'XCTest covers disposal cancellation'
Assert-Contains $validationDocs 'LifecycleTests' 'iOS XCTest validation boundary is documented'

Write-Output "PASS iOS lifecycle/export contract checks"
