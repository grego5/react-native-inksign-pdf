import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewLifecycleTests: XCTestCase {
  func testOverlayProviderRetainsContainerAndStableCanvasAccessor() {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }

    XCTAssertTrue(fixture.view.overlayProvider.canvasView === fixture.view.canvasView)
    XCTAssertTrue(fixture.view.overlayProvider.overlayView.superview ===
                  fixture.view.documentView)
    XCTAssertEqual(fixture.view.overlayProvider.overlayView.subviews.count, 1)
    XCTAssertTrue(fixture.view.overlayProvider.overlayView.subviews.first ===
                  fixture.view.canvasView)
  }

  func testCoordinatorUsesStablePageIdentityAndOwnsWorkingArtifact() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let document = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let activeID = document.activePageID
    let pageIDs = document.pages.map(\.id)
    let workingURL = document.workingURL

    XCTAssertEqual(document.activePage.id, activeID)
    XCTAssertEqual(document.index(of: activeID), 1)
    document.activePageIndex = 2
    XCTAssertEqual(document.activePage.id, document.pages[2].id)
    document.activePageIndex = 1
    XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))

    fixture.view.documentCoordinator.clearDocument()

    XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
    XCTAssertEqual(document.pages.map(\.id), pageIDs)
  }

  func testCoordinatorAdmissionDirtyAggregationAndArtifactCleanup() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let coordinator = fixture.view.documentCoordinator
    let originalDocument = try XCTUnwrap(coordinator.document)
    let open = try XCTUnwrap(coordinator.admit(.open))

    XCTAssertNil(coordinator.admit(.finalize), "conflicting work must be rejected")
    coordinator.settle(open, succeeded: false)
    XCTAssertTrue(coordinator.document.map { $0 === originalDocument } == true,
                  "a canceled open must leave the published document intact")
    let finalize = try XCTUnwrap(coordinator.admit(.finalize))
    let artifacts = try coordinator.allocateExportArtifacts(for: finalize)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.source.path))
    try Data("source snapshot".utf8).write(to: artifacts.source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.output.path))

    let document = try XCTUnwrap(coordinator.document)
    let page = document.pages[1]
    let annotation = makeCenteredTextAnnotation(
      id: "coordinator-dirty",
      text: "committed",
      fontSize: 18,
      pageSize: page.geometry.mediaBox.size)
    XCTAssertTrue(page.history.appendText(annotation))
    XCTAssertTrue(coordinator.isDirty)
    XCTAssertTrue(page.history.undo())
    XCTAssertFalse(coordinator.isDirty)

    coordinator.dispose()

    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.output.path))
    XCTAssertFalse(coordinator.isCurrent(finalize))
  }

  func testStaleExportCannotPublishOutput() throws {
    let coordinator = InkSignPdfDocumentCoordinator()
    let operation = try XCTUnwrap(coordinator.admit(.finalize))
    let artifacts = try coordinator.allocateExportArtifacts(for: operation)
    var publishInvoked = false
    _ = coordinator.nextGeneration()

    let published = try coordinator.publishOutput(artifacts.output, token: operation) {
      publishInvoked = true
    }

    XCTAssertFalse(published)
    XCTAssertFalse(publishInvoked)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.output.path))
    coordinator.finish(operation)
    coordinator.discardArtifact(artifacts.source)
  }

  func testFailedReplacementRestoresPublishedDocumentAndDeletesCandidate() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let coordinator = fixture.view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let sourceData = try Data(contentsOf: original.workingURL)
    let candidateURL = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try sourceData.write(to: candidateURL, options: .atomic)
    let candidatePDF = try XCTUnwrap(PDFDocument(url: candidateURL))
    let candidateSession = try InkSignPdfPdfiumSession(
      data: sourceData, fallbackFontPath: nil, collectionIndex: 0)
    let candidatePages = try (0..<candidatePDF.pageCount).map { index -> InkSignPdfPageState in
      let page = try XCTUnwrap(candidatePDF.page(at: index))
      return InkSignPdfPageState(
        page: page,
        geometry: PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation))
    }
    let candidate = InkSignPdfDocumentState(sourceURL: original.sourceURL,
                                            workingURL: candidateURL,
                                            document: candidatePDF,
                                            pdfiumSession: candidateSession,
                                            pages: candidatePages)
    let operation = try XCTUnwrap(coordinator.admit(.open))

    XCTAssertTrue(coordinator.publish(candidate, operation: operation))
    XCTAssertTrue(coordinator.document.map { $0 === candidate } == true)
    coordinator.settle(operation, succeeded: false)

    XCTAssertTrue(coordinator.document.map { $0 === original } == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.workingURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
  }

  func testOpenReadinessRequiresTheSameConditionsAsViewportCommands() {
    var readiness = ViewportReadiness(
      documentReady: true,
      viewInWindow: false,
      hasUsableBounds: true,
      activeOverlayAttached: true,
      fitScaleUsable: true)

    XCTAssertFalse(readiness.allowsCommand(fitToPage: false))

    readiness = ViewportReadiness(
      documentReady: true,
      viewInWindow: true,
      hasUsableBounds: true,
      activeOverlayAttached: true,
      fitScaleUsable: false)

    XCTAssertTrue(readiness.allowsCommand(fitToPage: false))
    XCTAssertFalse(readiness.allowsCommand(fitToPage: true))

    readiness = ViewportReadiness(
      documentReady: true,
      viewInWindow: true,
      hasUsableBounds: true,
      activeOverlayAttached: true,
      fitScaleUsable: true)

    XCTAssertTrue(readiness.allowsCommand(fitToPage: true))
  }

  func testOpenCompletionResolvesOnceWithoutLayoutReentry() {
    let fixture = makeFixture(applyInitialViewport: false)
    defer { fixture.window.isHidden = true }

    var resolutionCount = 0
    var rejectionCount = 0
    let promise = Promise<PageInfo>()
    promise.then { _ in resolutionCount += 1 }
    promise.catch { _ in rejectionCount += 1 }
    fixture.view.pendingOpen = InkSignView.PendingOpen(
      token: fixture.view.documentCoordinator.generation,
      promise: promise,
      zoom: 2,
      focus: CGPoint(x: 150, y: 200),
      fitToPage: false)

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])

    XCTAssertEqual(fixture.view.documentView.scaleFactor, 2, accuracy: 0.0001)
    XCTAssertEqual(resolutionCount, 1)
    XCTAssertEqual(rejectionCount, 0)
    XCTAssertNil(fixture.view.pendingOpen)

    fixture.view.documentView.layoutIfNeeded()

    XCTAssertEqual(fixture.view.documentView.scaleFactor, 2, accuracy: 0.0001)
    XCTAssertEqual(resolutionCount, 1)
    XCTAssertEqual(rejectionCount, 0)
  }

  func testExistingFocusRequestPreservesZoomWhenZoomIsOmitted() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    let initialZoom = fixture.view.documentView.scaleFactor

    try fixture.view.applyModeTransition(
      toEditing: false,
      request: .focus(CGPoint(x: 150, y: 200), zoom: nil))

    XCTAssertEqual(fixture.view.documentView.scaleFactor, initialZoom, accuracy: 0.0001)
  }

  func testProgrammaticPageSwitchCompletionDoesNotRetainView() {
    var completion: ((Result<PageInfo, Error>) -> Void)?
    weak var weakView: InkSignView?

    autoreleasepool {
      let view = InkSignView()
      weakView = view
      completion = view.programmaticPageSwitchCompletion()
    }

    XCTAssertNil(weakView)

    let info = PageInfo(pageIndex: 1, pageCount: 2, width: 612, height: 792)
    completion?(.success(info))
  }

  func testPageTurnGestureArmsMapsDirectionAndIssuesOneHaptic() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))

    guard let gesture = fixture.view.pageTurnLifecycle.pullingState else {
      return XCTFail("eligible pull should retain gesture state")
    }
    if case .some(.left) = gesture.physicalDirection {} else {
      XCTFail("negative pull should be classified as a leftward gesture")
    }
    XCTAssertEqual(gesture.targetDelta, 1)
    XCTAssertEqual(gesture.progress, 1)
    XCTAssertTrue(gesture.hapticIssued)
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)
    XCTAssertEqual(fixture.view.documentView.transform.a, 0.96, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -80, y: 0))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.pullingState?.hapticIssued == true)
  }

  func testPageTurnGestureCancellationReturnsPresentationToRest() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)
    XCTAssertEqual(fixture.view.documentView.transform.a, 0.96, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullCancelled()

    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("cancellation must remain in settlement until animation completion")
    }
    fixture.animationFactory.lastDriver?.advance(to: 0.35)
    XCTAssertGreaterThan(fixture.view.documentView.transform.a, 0.96)
    XCTAssertLessThanOrEqual(fixture.view.documentView.transform.a, 1)
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testPageTurnGestureMapsBothDirectionsInRTLAndLTR() {
    let cases: [(rtl: Bool, translation: CGFloat, delta: Int)] = [
      (false, 64, -1),
      (false, -64, 1),
      (true, 64, 1),
      (true, -64, -1),
    ]

    for testCase in cases {
      let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
      defer { fixture.window.isHidden = true }
      if testCase.rtl {
        fixture.view.documentView.semanticContentAttribute = .forceRightToLeft
        fixture.window.layoutIfNeeded()
        fixture.view.pageTurnLifecycle.stableContextChanged()
        fixture.previewScheduler.completeAll()
      }
      XCTAssertTrue(beginPull(in: fixture.view))
      fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: testCase.translation, y: 0))

      XCTAssertEqual(fixture.view.pageTurnLifecycle.pullingState?.targetDelta, testCase.delta)
      let physical: InkSignPdfEdgeNavigationPhysicalDirection = testCase.translation >= 0 ? .right : .left
      XCTAssertEqual(InkSignPdfPageTurnLifecycle.pageTurnTargetDelta(for: physical, isRTL: testCase.rtl),
                     testCase.delta)
    }
  }

  func testPageTurnPreviewDirectionSelectsTheSemanticNeighbor() {
    XCTAssertEqual(InkSignPdfPageTurnLifecycle.pageTurnTargetDelta(for: .left, isRTL: false), 1)
    XCTAssertEqual(InkSignPdfPageTurnLifecycle.pageTurnTargetDelta(for: .right, isRTL: false), -1)
    XCTAssertEqual(InkSignPdfPageTurnLifecycle.pageTurnTargetDelta(for: .left, isRTL: true), -1)
    XCTAssertEqual(InkSignPdfPageTurnLifecycle.pageTurnTargetDelta(for: .right, isRTL: true), 1)
  }

  func testPageTurnLifecycleKeepsGestureDataInsidePullingPhase() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("gesture ownership should enter the pulling phase")
    }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
  }

  func testStableContextReconciliationPreservesPullAndSettlementStates() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must not replace an active pull")
    }

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must preserve pulled presentation")
    }

    _ = fixture.view.documentCoordinator.nextGeneration()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("changed stable context must settle an active pull")
    }
    fixture.animationFactory.lastDriver?.complete()
    guard case .idle = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("context invalidation settlement must return to idle")
    }
    fixture.previewScheduler.completeAll()

    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must preserve rest settlement")
    }
  }

  func testSinglePageLifecycleDoesNotCreatePreviewState() {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(preparedPreview(.right, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.right, in: fixture.view))
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
  }

  func testTouchPreflightAcceptsOneReadyEligibleDirection() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let leftRequest = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("middle page should schedule the left preview")
    }
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.complete(request: leftRequest, image: UIImage())
    XCTAssertNotNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    let pageBounds = fixture.view.documentView.convert(
      fixture.pages[1].bounds(for: .mediaBox),
      from: fixture.pages[1])

    XCTAssertTrue(fixture.view.prepareForEdgeNavigationTouch(at: CGPoint(
      x: pageBounds.midX,
      y: pageBounds.midY)))
    guard case .pulling(let transaction) = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("one ready eligible direction should start a pull")
    }
    XCTAssertNotNil(transaction.previews[.left])
    XCTAssertNil(transaction.previews[.right])
  }

  func testRTLPreviewAndCommitUseTheNextPage() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.documentView.semanticContentAttribute = .forceRightToLeft
    fixture.window.layoutIfNeeded()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    fixture.previewScheduler.completeAll()

    XCTAssertEqual(preparedPreview(.right, in: fixture.view)?.key.targetPageIndex, 1)
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: 180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertTrue(fixture.view.documentView.currentPage === fixture.pages[1])
  }

  func testRepeatedStablePreviewReconciliationSubmitsOneRenderPerDirection() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count, 1)
    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count, 1)
    fixture.previewScheduler.completeAll()
    XCTAssertNotNil(preparedPreview(.left, in: fixture.view))
  }

  func testTwoEligibleDirectionsEachRetainOneInFlightRequest() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count, 2)
    XCTAssertNotNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count, 2)
  }

  func testChangingOnePreviewIdentityResubmitsOnlyThatDirection() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let left = renderingRequest(.left, in: fixture.view),
          let right = renderingRequest(.right, in: fixture.view) else {
      return XCTFail("both directions should have an initial request")
    }
    fixture.previewScheduler.complete(request: left, image: UIImage())
    fixture.previewScheduler.complete(request: right, image: UIImage())
    guard let state = fixture.view.documentCoordinator.document else { return XCTFail("fixture state missing") }
    state.pages[2].history.appendText(makeCenteredTextAnnotation(
      id: "preview-left-revision",
      text: "updated",
      fontSize: 16,
      pageSize: state.pages[2].geometry.mediaBox.size))

    fixture.view.pageTurnLifecycle.stableContextChanged()

    XCTAssertNotNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.right, in: fixture.view))
    XCTAssertEqual(preparedPreview(.right, in: fixture.view)?.key, right.key)
  }

  func testStalePreviewCompletionCannotClearNewerRequestAndFailureCanRetry() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let stale = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("initial left request should exist")
    }
    guard let state = fixture.view.documentCoordinator.document else { return XCTFail("fixture state missing") }
    state.pages[2].history.appendText(makeCenteredTextAnnotation(
      id: "preview-stale-revision",
      text: "updated",
      fontSize: 16,
      pageSize: state.pages[2].geometry.mediaBox.size))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let current = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("changed target should submit a replacement request")
    }

    fixture.previewScheduler.complete(request: stale, image: UIImage())
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, current.key)
    XCTAssertNil(preparedPreview(.left, in: fixture.view))

    fixture.previewScheduler.complete(request: current, image: nil)
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, current.key)
  }

  func testStaleSameKeyPreviewCompletionCannotClearReplacementRequest() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let first = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("initial preview request should exist")
    }

    fixture.view.overlayDidEndDisplaying(fixture.view.canvasView, for: fixture.pages[0])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let replacement = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("replacement preview request should exist")
    }
    XCTAssertEqual(first.key, replacement.key)

    fixture.previewScheduler.completeNext(image: nil)
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, replacement.key)

    fixture.previewScheduler.completeNext(image: UIImage())
    XCTAssertEqual(preparedPreview(.left, in: fixture.view)?.key, replacement.key)
  }

  func testTextAnnotationUsesExplicitLinesAndClipsCanonicalPosition() {
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "one\n\ntwo",
      fontSize: 16,
      pageSize: CGSize(width: 80, height: 40))

    XCTAssertEqual(annotation.text, "one\n\ntwo")
    XCTAssertGreaterThan(annotation.intrinsicSize.height, 2 * 16)
    XCTAssertLessThanOrEqual(annotation.bounds.maxX, 80)
    XCTAssertLessThanOrEqual(annotation.bounds.maxY, 40)
    XCTAssertEqual(annotation.position.x, (80 - annotation.intrinsicSize.width) / 2,
                   accuracy: 0.001)
  }

  func testTextRendererShapesMultilineLatinAndRTLInCanonicalPreviewSpace() {
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "Latin\nשלום עולם",
      fontSize: 18,
      pageSize: CGSize(width: 300, height: 200))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    var didDraw = false
    let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200),
                                        format: format).image { rendererContext in
      didDraw = InkSignPdfTextRenderer.drawForPreview(
        [annotation],
        pageSize: CGSize(width: 300, height: 200),
        mediaBox: CGRect(x: -12, y: 24, width: 300, height: 200),
        pdfToPreview: .identity,
        in: rendererContext.cgContext)
    }

    XCTAssertTrue(didDraw)
    XCTAssertEqual(image.size, CGSize(width: 300, height: 200))
    XCTAssertEqual(InkSignPdfTextRenderer.canonicalToPDFTransform(
      for: CGRect(x: -12, y: 24, width: 300, height: 200)).tx, -12, accuracy: 0.001)
  }

  func testTextRendererWritesExtractableTextToPDFContext() throws {
    let pageSize = CGSize(width: 300, height: 200)
    let mediaBox = CGRect(x: -12, y: 24, width: pageSize.width, height: pageSize.height)
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "Latin\nשלום עולם",
      fontSize: 18,
      pageSize: pageSize)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfTextRenderer-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    guard let consumer = CGDataConsumer(url: url as CFURL),
          var pageBox: CGRect = mediaBox,
          let context = CGContext(consumer: consumer,
                                  mediaBox: &pageBox,
                                  auxiliaryInfo: nil) else {
      return XCTFail("PDF context should be available")
    }
    context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
    try InkSignPdfTextRenderer.drawForPDF([annotation],
                                          pageSize: pageSize,
                                          mediaBox: mediaBox,
                                          in: context)
    context.endPDFPage()
    context.closePDF()

    let extracted = PDFDocument(url: url)?.page(at: 0)?.string ?? ""
    XCTAssertTrue(extracted.contains("Latin"))
    XCTAssertTrue(extracted.contains("שלום"))
  }

  func testPageContentHistoryRestoresTextAndClearAsOneAction() {
    let history = InkSignPdfPageContentHistory()
    let pageSize = CGSize(width: 400, height: 600)
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "before",
      fontSize: 16,
      pageSize: pageSize)
    history.appendText(annotation)
    history.replaceText(before: annotation,
                        with: annotation.replacingText("after\nline", pageSize: pageSize),
                        kind: .textEdit)

    XCTAssertEqual(history.content.textAnnotations.count, 1)
    XCTAssertEqual(history.undoStack.map(\.kind), [.textCreate, .textEdit])
    XCTAssertTrue(history.undo())
    XCTAssertEqual(history.content.textAnnotations[0].text, "before")
    XCTAssertTrue(history.redo())
    XCTAssertEqual(history.content.textAnnotations[0].text, "after\nline")

    history.clear()
    XCTAssertTrue(history.content.isEmpty)
    XCTAssertTrue(history.undo())
    XCTAssertEqual(history.content.textAnnotations,
                   [annotation.replacingText("after\nline", pageSize: pageSize)])
    XCTAssertTrue(history.state.isDirty)
  }

  func testPageContentHistoryIsPageLocalAndSnapshotCarriesCommittedText() {
    let first = InkSignPdfPageContentHistory()
    let second = InkSignPdfPageContentHistory()
    let annotation = makeCenteredTextAnnotation(
      id: "first",
      text: "page one",
      fontSize: 18,
      pageSize: CGSize(width: 300, height: 300))

    first.appendText(annotation)

    XCTAssertEqual(first.content.textAnnotations, [annotation])
    XCTAssertTrue(first.state.isDirty)
    XCTAssertFalse(second.state.isDirty)
  }

  func testTextInteractionRejectsPlacementWithoutReadyPresentation() {
    let overlay = InkSignPdfTextInteractionOverlay(frame: .zero)

    XCTAssertThrowsError(try overlay.armPlacement(generation: 0)) { error in
      guard let textError = error as? InkSignView.TextError,
            case .notReady = textError else {
        return XCTFail("text placement must reject before a page overlay is ready")
      }
    }
  }

  func testTextPlacementOnAndOffAreIdempotent() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try fixture.view.insertAnnotationOn()
    try fixture.view.insertAnnotationOn()
    XCTAssertTrue(overlay.hasPendingPlacement())
    XCTAssertNil(textEditor(in: overlay))

    try fixture.view.insertAnnotationOff()
    try fixture.view.insertAnnotationOff()
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNil(textEditor(in: overlay))
  }

  func testTextPlacementConsumesOneRoutedTap() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let placementPoint = CGPoint(x: 120, y: 180)

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.hitTest(placementPoint, with: nil) === overlay)
    XCTAssertTrue(overlay.routePlacementTap(at: placementPoint))
    XCTAssertFalse(overlay.hasPendingPlacement())
    let firstEditor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertTrue(overlay.interactionMode() == .textediting)

    let secondPoint = CGPoint(x: 20, y: 380)
    XCTAssertTrue(overlay.routeTouchBegan(at: secondPoint))
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertFalse(overlay.routeTouchBegan(at: secondPoint))
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations.count, 0)
    XCTAssertNil(overlay.hitTest(secondPoint, with: nil))
    XCTAssertFalse(firstEditor.isDescendant(of: overlay))
  }

  func testTextPlacementOutsideTapDiscardsEmptyDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)

    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    let outside = CGPoint(x: 10, y: 390)

    XCTAssertTrue(overlay.routeTouchBegan(at: outside))
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertFalse(editor.isDescendant(of: overlay))
    XCTAssertTrue(fixture.view.documentCoordinator.document?.activePage.history.content.isEmpty == true)
  }

  func testTextPlacementOutsideTapUsesTransformedEditorCoordinates() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.transform = CGAffineTransform(rotationAngle: .pi / 4)

    let inside = editor.convert(CGPoint(x: editor.bounds.midX,
                                        y: editor.bounds.midY), to: overlay)
    XCTAssertFalse(overlay.routeTouchBegan(at: inside))
    XCTAssertTrue(textEditor(in: overlay) === editor)

    let outside = editor.convert(CGPoint(x: editor.bounds.maxX + 20,
                                         y: editor.bounds.midY), to: overlay)
    XCTAssertTrue(overlay.routeTouchBegan(at: outside))
    XCTAssertNil(textEditor(in: overlay))
  }

  func testTextPlacementOutsideTapCommitsNonEmptyDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "signed"
    overlay.textViewDidChange(editor)
    XCTAssertTrue(overlay.interactionMode() == .textediting)

    XCTAssertTrue(overlay.routeTouchBegan(at: CGPoint(x: 10, y: 390)))
    let annotations = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].text, "signed")
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.undoStack.map(\.kind), [.textCreate])
  }

  func testTextPlacementCancelsOnModeAndPageChange() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    fixture.view.setInteractionMode(editing: true)
    XCTAssertFalse(overlay.hasPendingPlacement())

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    try fixture.view.switchPage(to: 1) { result in
      if case .failure(let error) = result {
        XCTFail("unexpected page switch failure: \(error)")
      }
    }
    XCTAssertFalse(overlay.hasPendingPlacement())
  }

  func testTextPlacementCancelsOnDocumentReplacementAndDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    fixture.view.beginLoad("",
                          zoom: nil,
                          focus: nil,
                          fitToPage: true,
                          promise: Promise<PageInfo>())
    XCTAssertFalse(overlay.hasPendingPlacement())

    let disposalFixture = makeFixture(pageCount: 1)
    defer { disposalFixture.window.isHidden = true }
    let disposalOverlay = disposalFixture.view.textInteractionOverlay
    try disposalOverlay.armPlacement(generation: disposalFixture.view.documentCoordinator.generation)
    disposalFixture.view.dispose()
    XCTAssertFalse(disposalOverlay.hasPendingPlacement())
  }

  func testTextPlacementUsesCanonicalZoomedPanCoordinate() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    fixture.view.pageToOverlayTransform = CGAffineTransform(a: 2, b: 0, c: 0, d: 2,
                                                             tx: 30, ty: 40)
    let pagePoint = CGPoint(x: 80, y: 120)
    let overlayPoint = pagePoint.applying(fixture.view.pageToOverlayTransform!)

    XCTAssertEqual(fixture.view.canonicalPagePoint(fromOverlay: overlayPoint), pagePoint)
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: overlayPoint))
    XCTAssertFalse(overlay.hasPendingPlacement())
    let editor = try XCTUnwrap(textEditor(in: overlay))
    let placeholderSize = InkSignPdfTextRenderer.layout(text: "M", fontSize: 16).size
    let expectedOrigin = CGPoint(x: pagePoint.x - placeholderSize.width / 2,
                                 y: pagePoint.y - placeholderSize.height / 2)
    editor.text = "signed"

    XCTAssertTrue(overlay.routeTouchBegan(at: CGPoint(x: 10, y: 390)))
    let annotations = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].position.x, expectedOrigin.x, accuracy: 0.001)
    XCTAssertEqual(annotations[0].position.y, expectedOrigin.y, accuracy: 0.001)
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.undoStack.map(\.kind), [.textCreate])
  }

  func testRTLTextKeepsTheEditingRightEdgeOnCommit() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "שלום"
    overlay.textViewDidChange(editor)

    let inverse = try XCTUnwrap(fixture.view.pageToOverlayTransform).inverted()
    let center = editor.center.applying(inverse)
    let contentSize = InkSignPdfTextRenderer.layout(text: "שלום", fontSize: 16).size
    let editingRightEdge = center.x + contentSize.width / 2
    XCTAssertTrue(overlay.routeTouchBegan(at: CGPoint(x: 10, y: 390)))

    let annotations = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].bounds.maxX, editingRightEdge, accuracy: 0.001)
  }

  func testLongPressIsEligibleOnlyWhenTouchStartsOnCommittedText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let annotation = makeCenteredTextAnnotation(id: "text-1", text: "note",
                                                 fontSize: 16,
                                                 pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(annotation,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)

    XCTAssertEqual(overlay.dragTarget(at: CGPoint(x: annotation.bounds.midX,
                                                   y: annotation.bounds.midY)), annotation.id)
    XCTAssertNil(overlay.dragTarget(at: CGPoint(x: 10, y: 390)))
  }

  func testTextAnnotationIDsAreMonotonicAndUnique() {
    let view = InkSignView()

    XCTAssertEqual(view.allocateTextAnnotationID(), "text-1")
    XCTAssertEqual(view.allocateTextAnnotationID(), "text-2")
  }

  func testDisposalRejectsDelayedPreviewCompletion() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let request = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("disposal test should have a queued preview")
    }

    fixture.view.dispose()
    fixture.previewScheduler.complete(request: request, image: UIImage())

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testDocumentReplacementRejectsDelayedPreviewCompletion() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let request = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("replacement test should have a queued preview")
    }

    _ = fixture.view.documentCoordinator.nextGeneration()
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.previewScheduler.complete(request: request, image: UIImage())

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
  }

  func testPageTurnPreviewUsesFitCenteredTargetFrame() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }

    guard let preview = preparedPreview(.left, in: fixture.view) else {
      return XCTFail("next-page preview should be prepared")
    }
    XCTAssertEqual(preview.frame.midX, fixture.view.documentView.bounds.midX, accuracy: 0.5)
    XCTAssertEqual(preview.frame.midY, fixture.view.documentView.bounds.midY, accuracy: 0.5)
    XCTAssertEqual(preview.key.targetPageIndex, 1)
  }

  func testPageTurnScaleChangesOnlyDuringLatePull() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -64, y: 0))
    XCTAssertEqual(fixture.view.documentView.transform.a, 1, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -146, y: 0))
    XCTAssertLessThan(fixture.view.documentView.transform.a, 1)
    XCTAssertGreaterThan(fixture.view.documentView.transform.a, 0.96)
  }

  func testArmedPageTurnChangesPageExactlyOnce() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertNotNil(fixture.view.pendingPageSwitchID)
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
    XCTAssertTrue(fixture.view.documentView.currentPage === fixture.pages[1])
  }

  func testSubthresholdPageTurnSettlesPreviewWithPageBeforeClearing() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    let initialOffset = abs(fixture.view.documentView.transform.tx)

    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)

    fixture.animationFactory.lastDriver?.advance(to: 0.35)
    XCTAssertLessThan(abs(fixture.view.documentView.transform.tx), initialOffset)
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)

    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testRetreatBelowDeadZoneUsesIdentityCheckedRestSettlement() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    let activePage = fixture.view.documentCoordinator.document?.activePageIndex

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -4, y: 0))

    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("retreat below the dead zone must settle through the lifecycle")
    }
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePageIndex, activePage)
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testReversalAndLossOfHorizontalDominanceUseRestSettlement() {
    for translation in [CGPoint(x: 32, y: 0), CGPoint(x: -4, y: 40)] {
      let fixture = makeFixture()
      defer { fixture.window.isHidden = true }
      XCTAssertTrue(beginPull(in: fixture.view))
      fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
      fixture.view.pageTurnLifecycle.pullChanged(translation: translation)

      guard case .settling = fixture.view.pageTurnLifecycle.phase else {
        return XCTFail("invalidated pull must use rest settlement")
      }
      fixture.animationFactory.lastDriver?.complete()
      XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
      XCTAssertEqual(fixture.view.documentCoordinator.document?.activePageIndex, 0)
    }
  }

  func testNewGestureCancelsStalePageTurnSettlement() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    XCTAssertTrue(fixture.view.prepareForEdgeNavigationTouch(at: CGPoint(x: 300, y: 300)))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -24, y: 0))
    let newOffset = abs(fixture.view.documentView.transform.tx)

    XCTAssertNil(staleDriver)
    staleCallback?.advance(to: 0.35)
    XCTAssertEqual(abs(fixture.view.documentView.transform.tx), newOffset, accuracy: 0.0001)
    staleCallback?.complete()
    XCTAssertEqual(abs(fixture.view.documentView.transform.tx), newOffset, accuracy: 0.0001)
    XCTAssertGreaterThan(newOffset, 0)
  }

  func testCompletedSettlementDriverIsReleased() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    beginSubthresholdSettlement(in: fixture.view)
    weak var weakAnimation = fixture.view.pageTurnLifecycle.settlementDriver
    XCTAssertNotNil(weakAnimation)

    fixture.animationFactory.lastDriver?.complete()

    XCTAssertNil(weakAnimation)
    XCTAssertNil(fixture.view.pageTurnLifecycle.settlementDriver)
  }

  func testCancelledSettlementDriverIsReleased() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    beginSubthresholdSettlement(in: fixture.view)
    weak var weakAnimation = fixture.view.pageTurnLifecycle.settlementDriver
    XCTAssertNotNil(weakAnimation)

    fixture.view.pageTurnLifecycle.cancelSettlement()

    XCTAssertNil(weakAnimation)
    XCTAssertNil(fixture.view.pageTurnLifecycle.settlementDriver)
  }

  func testModeChangeCancelsPageTurnSettlementBeforeStaleCallback() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    fixture.view.setInteractionMode(editing: true)
    XCTAssertNil(staleDriver)
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.advance(to: 0.35)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testDisposalCancelsPageTurnSettlementBeforeStaleCallback() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    fixture.view.dispose()
    XCTAssertNil(staleDriver)
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    staleCallback?.advance(to: 0.35)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testPageSwitchWaitsForOverlayHandoffBeforeCompleting() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      if case .failure(let error) = result {
        XCTFail("unexpected page switch failure: \(error)")
      }
    }

    XCTAssertNotNil(fixture.view.pendingPageSwitchID)

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertTrue(fixture.view.documentView.currentPage === fixture.pages[1])
  }

  func testCommittedOverlayDetachmentPreservesSnapshotAndSwitchIdentity() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()

    guard let switchID = fixture.view.pendingPageSwitchID,
          case .committed(let handoff) = fixture.view.pageTurnLifecycle.phase,
          handoff.progress == .waiting(switchID) else {
      return XCTFail("armed gesture should wait for the matching live target")
    }
    let retainedKey = handoff.preview.key
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)

    fixture.view.pageTurnLifecycle.overlayDetached()

    guard case .committed(let detachedHandoff) = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("overlay detachment must preserve the committed handoff")
    }
    XCTAssertEqual(detachedHandoff.progress, .waiting(switchID))
    XCTAssertEqual(detachedHandoff.preview.key, retainedKey)
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.currentPage === fixture.pages[1])
  }

  func testStaleSwitchIDsCannotCompleteCommittedHandoff() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()

    guard let switchID = fixture.view.pendingPageSwitchID else {
      return XCTFail("armed turn should create a pending switch")
    }
    XCTAssertFalse(fixture.view.pageTurnLifecycle.pageSwitchReady(switchID: switchID &+ 1))
    fixture.view.pageTurnLifecycle.pageSwitchCancelled(switchID: switchID &+ 1)
    fixture.view.pageTurnLifecycle.pageSwitchFailed(switchID: switchID &+ 1)
    guard case .committed = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stale switch IDs must not release the handoff")
    }

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
  }

  func testPendingPageSwitchCancellationIsExactlyOnceAgainstDelayedCallback() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      guard case .failure(let error) = result else {
        XCTFail("cancellation must fail the pending request")
        return
      }
      guard let viewportError = error as? InkSignView.ViewportError else {
        XCTFail("cancellation must use the viewport cancellation error")
        return
      }
      guard case .cancelled = viewportError else {
        XCTFail("cancellation must use the viewport cancellation error")
        return
      }
    }

    fixture.view.cancelPendingPageSwitch()
    fixture.view.cancelPendingPageSwitch()
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
  }

  func testDocumentReplacementCancelsPendingPageSwitchExactlyOnce() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      guard case .failure(let error) = result,
            let viewportError = error as? InkSignView.ViewportError else {
        XCTFail("replacement must cancel the pending request")
        return
      }
      guard case .cancelled = viewportError else {
        XCTFail("replacement must cancel the pending request")
        return
      }
    }

    fixture.view.beginLoad(
      "",
      zoom: nil,
      focus: nil,
      fitToPage: true,
      promise: Promise<PageInfo>())
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertEqual(completionCount, 1)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
  }

  func testDisposalCancelsPendingPageSwitchExactlyOnce() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      guard case .failure(let error) = result,
            let viewportError = error as? InkSignView.ViewportError else {
        XCTFail("disposal must cancel the pending request")
        return
      }
      guard case .cancelled = viewportError else {
        XCTFail("disposal must cancel the pending request")
        return
      }
    }

    fixture.view.dispose()
    fixture.view.dispose()

    XCTAssertEqual(completionCount, 1)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
  }

  private func makeFixture(
    pageCount: Int = 2,
    activePageIndex: Int = 0,
    applyInitialViewport: Bool = true
  ) -> (view: InkSignView, window: UIWindow, pages: [PDFPage],
        previewScheduler: TestPreviewScheduler,
        animationFactory: TestAnimationDriverFactory) {
    let document = PDFDocument()
    let pages = (0..<pageCount).map { index -> PDFPage in
      let image = UIGraphicsImageRenderer(size: CGSize(width: 300 + index * 100, height: 400))
        .image { UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400)) }
      let page = PDFPage(image: image)!
      page.setBounds(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400), for: .mediaBox)
      document.insert(page, at: index)
      return page
    }
    let states = pages.enumerated().map { index, page in
      InkSignPdfPageState(page: page,
                          geometry: PageGeometry(mediaBox: page.bounds(for: .mediaBox),
                                                 rotation: page.rotation))
    }
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfLifecycle-\(UUID().uuidString).pdf")
    XCTAssertTrue(document.write(to: sourceURL))
    let sourceData = try! Data(contentsOf: sourceURL)
    let workingURL = try! InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try! sourceData.write(to: workingURL, options: .atomic)
    let pdfiumSession = try! InkSignPdfPdfiumSession(
      data: sourceData, fallbackFontPath: nil, collectionIndex: 0)
    XCTAssertEqual(Int(pdfiumSession.pageCount), pageCount)
    let previewScheduler = TestPreviewScheduler()
    let animationFactory = TestAnimationDriverFactory()
    let view = InkSignView(
      previewScheduler: previewScheduler,
      animationDriverFactory: animationFactory)
    let state = InkSignPdfDocumentState(
      sourceURL: sourceURL,
      workingURL: workingURL,
      document: document,
      pdfiumSession: pdfiumSession,
      pages: states)
    state.activePageIndex = activePageIndex
    XCTAssertTrue(view.documentCoordinator.publish(state, generation: view.documentCoordinator.generation))
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    view.documentView.installPage(
      index: activePageIndex,
      page: pages[activePageIndex],
      geometry: states[activePageIndex].geometry,
      session: pdfiumSession,
      generation: view.documentCoordinator.generation)
    view.documentView.layoutIfNeeded()
    if applyInitialViewport {
      XCTAssertTrue(view.documentView.applyViewport(
        zoom: view.documentView.scaleFactorForSizeToFit,
        focus: CGPoint(x: 150, y: 200),
        generation: view.documentCoordinator.generation))
    }
    view.canvasView.frame = view.documentView.bounds
    view.attachedOverlayPage = pages[activePageIndex]
    view.overlayTransformPage = pages[activePageIndex]
    view.pageToOverlayTransform = .identity
    view.pageTurnLifecycle.stableContextChanged()
    previewScheduler.completeAll()
    return (view, window, pages, previewScheduler, animationFactory)
  }

  private func preparedPreview(
    _ direction: InkSignPdfEdgeNavigationPhysicalDirection,
    in view: InkSignView
  ) -> InkSignPdfPageTurnLifecycle.PreparedPreview? {
    guard case .some(.ready(let preview)) = view.pageTurnLifecycle.previewSlots[direction] else {
      return nil
    }
    return preview
  }

  private func renderingRequest(
    _ direction: InkSignPdfEdgeNavigationPhysicalDirection,
    in view: InkSignView
  ) -> InkSignPdfPageTurnPreviewRequest? {
    guard case .some(.rendering(let rendering)) = view.pageTurnLifecycle.previewSlots[direction] else {
      return nil
    }
    return rendering.request
  }

  private func isIdle(_ lifecycle: InkSignPdfPageTurnLifecycle) -> Bool {
    if case .idle = lifecycle.phase { return true }
    return false
  }

  private func beginSubthresholdSettlement(in view: InkSignView) {
    XCTAssertTrue(beginPull(in: view))
    view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    view.pageTurnLifecycle.pullEnded()
  }

  @discardableResult
  private func beginPull(in view: InkSignView) -> Bool {
    let location = CGPoint(x: view.documentView.bounds.midX,
                           y: view.documentView.bounds.midY)
    return view.prepareForEdgeNavigationTouch(at: location)
  }
}

private func textEditor(in overlay: InkSignPdfTextInteractionOverlay) -> UITextView? {
  overlay.subviews.compactMap { $0 as? UITextView }.first
}

private func makeCenteredTextAnnotation(
  id: String,
  text: String,
  fontSize: CGFloat,
  pageSize: CGSize
) -> InkSignPdfTextAnnotation {
  let size = InkSignPdfTextAnnotation.intrinsicSize(of: text, fontSize: fontSize)
  let x = size.width >= pageSize.width
    ? (pageSize.width - size.width) / 2
    : min(max((pageSize.width - size.width) / 2, 0), pageSize.width - size.width)
  let y = size.height >= pageSize.height
    ? (pageSize.height - size.height) / 2
    : min(max((pageSize.height - size.height) / 2, 0), pageSize.height - size.height)
  return InkSignPdfTextAnnotation(id: id,
                                  text: text,
                                  bounds: CGRect(x: x, y: y,
                                                 width: size.width, height: size.height),
                                  fontSize: fontSize)
}

private final class TestPreviewScheduler: InkSignPdfPageTurnPreviewScheduler {
  final class Job {
    let request: InkSignPdfPageTurnPreviewRequest
    let completion: (UIImage?) -> Void

    init(request: InkSignPdfPageTurnPreviewRequest, completion: @escaping (UIImage?) -> Void) {
      self.request = request
      self.completion = completion
    }
  }

  private(set) var submittedRequests: [InkSignPdfPageTurnPreviewRequest] = []
  private var jobs: [Job] = []

  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void
  ) {
    submittedRequests.append(request)
    jobs.append(Job(request: request, completion: completion))
  }

  func completeNext(image: UIImage? = UIImage()) {
    precondition(!jobs.isEmpty, "expected a queued preview job")
    let job = jobs.removeFirst()
    job.completion(image)
  }

  func completeAll(image: UIImage? = UIImage()) {
    while !jobs.isEmpty {
      completeNext(image: image)
    }
  }

  func complete(request: InkSignPdfPageTurnPreviewRequest, image: UIImage?) {
    guard let index = jobs.firstIndex(where: { $0.request.key == request.key }) else {
      preconditionFailure("expected a queued preview request")
    }
    let job = jobs.remove(at: index)
    job.completion(image)
  }
}

private final class TestAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory {
  weak var lastDriver: TestAnimationDriver?
  private(set) var callbackHandles: [TestAnimationCallbackHandle] = []

  var lastCallback: TestAnimationCallbackHandle? {
    callbackHandles.last
  }

  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver {
    let callback = TestAnimationCallbackHandle(update: update, finish: finish)
    callbackHandles.append(callback)
    let driver = TestAnimationDriver(callback: callback)
    lastDriver = driver
    return driver
  }
}

private final class TestAnimationCallbackHandle {
  private let update: (CGFloat) -> Void
  private let finish: () -> Void

  init(update: @escaping (CGFloat) -> Void, finish: @escaping () -> Void) {
    self.update = update
    self.finish = finish
  }

  func advance(to progress: CGFloat) {
    update(progress)
  }

  func complete() {
    update(1)
    finish()
  }
}

private final class TestAnimationDriver: InkSignPdfPageTurnAnimationDriver {
  private let callback: TestAnimationCallbackHandle

  init(callback: TestAnimationCallbackHandle) {
    self.callback = callback
  }

  func start() {}
  func stop() {}
  func advance(to progress: CGFloat) { callback.advance(to: progress) }
  func complete() { callback.complete() }
}
