import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewLifecycleTests: XCTestCase, InkSignViewTestSupport {
  func testZoomReportsSettledFitRelativeScaleAndEachPage() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    var reports: [Double] = []
    var pending: XCTestExpectation?
    view.onZoomChange = { zoom in reports.append(zoom); pending?.fulfill() }
    func expectZoom(_ expected: Double, change: () throws -> Void) throws {
      let next = expectation(description: "settled normalized zoom \(expected)")
      pending = next
      let count = reports.count
      try change()
      XCTAssertEqual(reports.count, count)
      wait(for: [next], timeout: 5)
      pending = nil
      XCTAssertEqual(try XCTUnwrap(reports.last), expected, accuracy: 0.000001)
    }
    try expectZoom(1) { view.scheduleZoomReport() }
    let fit = try XCTUnwrap(view.usableFitScale())
    try expectZoom(2) {
      view.applyViewport(request: .focus(nil, zoom: Double(fit * 2)))
    }
    try expectZoom(0.75) {
      view.applyViewport(request: .focus(nil, zoom: Double(fit * 0.75)))
    }
    try expectZoom(1) { _ = try view.switchPage(to: 1); view.applyViewport(request: .fit) }
    try expectZoom(1) { _ = try view.switchPage(to: 0); view.applyViewport(request: .fit) }
  }

  func testOpenDetectsJpegWithoutExtensionAndCreatesOnePdfPage() throws {
    let fixture = makeFixture(pageCount: 1)
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignJpegOpen-\(UUID().uuidString).bin")
    defer {
      try? FileManager.default.removeItem(at: source)
      fixture.view.dispose()
      fixture.window.isHidden = true
    }
    let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
    }
    let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    try bytes.write(to: source)
    let info = try awaitRotationOperation(fixture.view.open(path: source.absoluteString, options: nil))
    XCTAssertEqual(info.pageCount, 1)
    XCTAssertEqual(info.width, 595.28, accuracy: 0.01)
    XCTAssertEqual(info.height, 841.89, accuracy: 0.01)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let exported = try XCTUnwrap(PDFDocument(url: state.workingURL))
    XCTAssertEqual(exported.pageCount, 1)
  }

  func testCoordinateTapUsesDisplayedPagePointsAndConsumesOnlyOnce() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    try awaitRotationOperation(view.rotatePage(degrees: 90))
    let request = try view.getPageCoords()
    var requestError: Error?
    request.catch { requestError = $0 }
    // A later command completing proves the tap wait released the FIFO queue.
    try awaitModeChange(view.enqueueViewerCommand { Promise<Void>.resolved() })
    XCTAssertNil(requestError, "Coordinate selection failed before the user tapped")
    XCTAssertTrue(view.isPickingPageCoords)
    XCTAssertTrue(view.interactionMode() == .pagecoords)
    let page = try XCTUnwrap(view.documentCoordinator.document?.activePage)
    let point = CGPoint(x: 60, y: 90)
    let location = view.documentView.convert(point.applying(page.geometry.displayToPDFTransform), from: page.page)
    let tap = CoordinateTap(location: location)
    var results: [PageCoords] = []
    request.then { results.append($0) }
    view.handleCoordinateTap(tap)
    view.handleCoordinateTap(tap)
    XCTAssertEqual(results.count, 1)
    let result = try XCTUnwrap(results.first)
    XCTAssertEqual(result.pageId, page.id.uuidString)
    XCTAssertEqual(result.pageIndex, 0)
    XCTAssertEqual(result.x, 60, accuracy: 0.001)
    XCTAssertEqual(result.y, 90, accuracy: 0.001)
    XCTAssertFalse(view.isPickingPageCoords)
    XCTAssertTrue(view.interactionMode() == .view)
    XCTAssertTrue(page.history.content.textAnnotations.isEmpty)
    XCTAssertTrue(page.history.content.drawing.strokes.isEmpty)
  }

  func testCoordinateRequestsCancelOnModeChangeCloseAndDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    var errors: [Error] = []
    try view.getPageCoords().catch { errors.append($0) }
    try awaitModeChange(view.setViewMode(viewport: nil))
    try awaitModeChange(view.setViewMode(viewport: nil))
    try view.getPageCoords().catch { errors.append($0) }
    try awaitRotationOperation(view.close(cancelPending: false))
    XCTAssertEqual(errors.count, 2)
    XCTAssertFalse(view.isPickingPageCoords)
    XCTAssertNil(view.pendingPageCoords)
    // Queue admission is deliberately held so disposal also covers a not-yet-armed request.
    let held = Promise<Void>()
    view.enqueueViewerCommand { held }
    try view.getPageCoords().catch { errors.append($0) }
    view.dispose()
    XCTAssertEqual(errors.count, 3)
    XCTAssertTrue(errors.allSatisfy { $0.localizedDescription.hasPrefix("operation_cancelled:") })
  }

  func testCoordinatePickerCancelsWhenItsCapturedPageChanges() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let firstPageID = try XCTUnwrap(view.documentCoordinator.document?.activePage.id)
    var errors: [Error] = []
    var coordinates: [PageCoords] = []
    try view.getPageCoords().then { coordinates.append($0) }.catch { errors.append($0) }
    try awaitModeChange(view.enqueueViewerCommand { Promise<Void>.resolved() })
    XCTAssertTrue(view.interactionMode() == .pagecoords)
    try view.switchPage(to: 1)
    XCTAssertNotEqual(view.documentCoordinator.document?.activePage.id, firstPageID)
    view.handleCoordinateTap(CoordinateTap(location: CGPoint(x: 100, y: 100)))
    XCTAssertTrue(coordinates.isEmpty)
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].localizedDescription.hasPrefix("operation_cancelled:"))
    XCTAssertNil(view.pendingPageCoords)
    XCTAssertTrue(view.interactionMode() == .view)
  }

  func testImmediateCloseRejectsRunningAndQueuedViewerCommands() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let neverFinishes = Promise<PageInfo>()
    let running = fixture.view.enqueueViewerCommand { neverFinishes }
    let queued = fixture.view.enqueueViewerCommand { Promise<PageInfo>.resolved(withResult:
      PageInfo(pageIndex: 0, pageCount: 1, width: 300, height: 400)) }
    let queuedMode = try fixture.view.setInkMode(viewport: nil)
    var cancellationCount = 0
    running.catch { _ in cancellationCount += 1 }
    queued.catch { _ in cancellationCount += 1 }
    queuedMode.catch { _ in cancellationCount += 1 }
    try awaitRotationOperation(fixture.view.close(cancelPending: true))
    XCTAssertEqual(cancellationCount, 3)
    XCTAssertNil(fixture.view.documentCoordinator.document)
    try awaitModeChange(fixture.view.setInkMode(viewport: nil))
    try awaitModeChange(fixture.view.setTextMode(options: nil))
    try awaitModeChange(fixture.view.setViewMode(viewport: nil))
    XCTAssertNil(fixture.view.documentCoordinator.document)
    XCTAssertFalse(fixture.view.editMode)
    XCTAssertFalse(fixture.view.textInteractionOverlay.hasPendingPlacement())
    // Late completion cannot revive the cancelled queue or current document.
    neverFinishes.resolve(withResult: PageInfo(pageIndex: 0, pageCount: 1, width: 300, height: 400))
    XCTAssertNil(fixture.view.documentCoordinator.document)
  }

  func testFifoCloseAndReplacementPreserveDocumentOrder() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let source = try XCTUnwrap(fixture.view.documentCoordinator.document?.workingURL)
    let replacementSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    try FileManager.default.copyItem(at: source, to: replacementSource)
    defer { try? FileManager.default.removeItem(at: replacementSource) }
    var identities: [String?] = []
    fixture.view.onStateChange = { state in
      identities.append(state.documentId?.asType(String.self))
    }
    let preparedRequest = try fixture.view.getPage(pageIndex: nil)
    let closing = try fixture.view.close(cancelPending: false)
    let opening = try fixture.view.open(path: replacementSource.path, options: nil)
    let replacementAnalysis = try fixture.view.getPage(pageIndex: nil)
    let prepared = try awaitRotationOperation(preparedRequest)
    try awaitRotationOperation(closing)
    _ = try awaitRotationOperation(opening)
    _ = try awaitRotationOperation(replacementAnalysis)
    XCTAssertThrowsError(try prepared.getTextEntries())
    XCTAssertEqual(Set(identities.compactMap { $0 }).count, 2)
    XCTAssertTrue(identities.contains(where: { $0 == nil }))
    let output = try awaitRotationOperation(fixture.view.finalize())
    XCTAssertTrue(output.hasPrefix("file://"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: output)).path))
  }

  func testPDFViewOwnsPresentationAndRequestsPageSpecificOverlays() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.window.isHidden = true }

    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let first = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: state.pages[0].page))
    let second = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: state.pages[1].page))

    XCTAssertEqual(fixture.view.documentView.displayMode, .singlePage)
    XCTAssertTrue(fixture.view.documentView.pageOverlayViewProvider ===
                  fixture.view.overlayProvider)
    XCTAssertTrue(fixture.view.documentView.currentPage === state.activePage.page)
    XCTAssertEqual(fixture.view.documentView.backgroundColor, UIColor.white)
    XCTAssertFalse(first === second)
    XCTAssertTrue(fixture.view.overlayProvider.canvasView === fixture.view.canvasView)
  }

  func testEndedPageOverlayCanBeRecreatedFromCoordinatorState() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let page = state.activePage.page
    let pageID = state.activePage.id
    let history = state.activePage.history
    let before = history.content
    let point = PKStrokePoint(location: CGPoint(x: 80, y: 90),
                              timeOffset: 0,
                              size: CGSize(width: 4, height: 4),
                              opacity: 1,
                              force: 0.5,
                              azimuth: 0,
                              altitude: .pi / 2)
    let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                          path: PKStrokePath(controlPoints: [point], creationDate: Date()),
                          transform: .identity,
                          mask: nil)
    XCTAssertTrue(history.record(type: .ink,
                                 before: before,
                                 after: before.replacingDrawing(PKDrawing(strokes: [stroke]))))
    let committedContent = state.activePage.history.content
    let oldOverlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: page))

    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willEndDisplayingOverlayView: oldOverlay,
                                         for: page)
    let newOverlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: page))
    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willDisplayOverlayView: newOverlay,
                                         for: page)
    let newCanvas = try XCTUnwrap((newOverlay as? InkSignPdfPageOverlayView)?.canvasView)

    XCTAssertFalse(oldOverlay === newOverlay)
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.id, pageID)
    XCTAssertTrue(state.activePage.history.content.equals(committedContent))
    XCTAssertEqual(newCanvas.drawing.strokes.count, 1)
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
    XCTAssertTrue(fixture.view.documentCoordinator.selectPage(at: 2))
    XCTAssertEqual(document.activePage.id, document.pages[2].id)
    XCTAssertTrue(fixture.view.documentCoordinator.selectPage(at: 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))

    fixture.view.documentCoordinator.clearDocument()
    fixture.view.documentCoordinator.pdfQueue.sync {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
    XCTAssertEqual(document.pages.map(\.id), pageIDs)
  }

  func testCoordinatorAdmissionDirtyAggregationAndArtifactCleanup() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let coordinator = fixture.view.documentCoordinator
    let originalDocument = try XCTUnwrap(coordinator.document)
    let page = originalDocument.pages[1]
    let annotation = makeCenteredTextAnnotation(
      id: 11,
      text: "committed",
      fontSize: 18,
      pageSize: page.geometry.mediaBox.size)
    XCTAssertTrue(page.history.appendText(annotation))
    XCTAssertTrue(coordinator.isDirty)
    XCTAssertTrue(page.history.undo())
    XCTAssertFalse(coordinator.isDirty)

    let finalize = try XCTUnwrap(coordinator.admit(.finalize))
    let artifacts = try coordinator.allocateExportArtifacts(for: finalize)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.source.path))
    try Data("source snapshot".utf8).write(to: artifacts.source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.output.path))

    let open = try XCTUnwrap(coordinator.admit(.open))
    XCTAssertNil(coordinator.document, "open admission clears the previous document")
    XCTAssertFalse(coordinator.isCurrent(finalize), "replacement invalidates finalize")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.source.path),
                  "replacement leaves worker-owned export input until worker cleanup")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.output.path),
                  "replacement leaves worker-owned output until worker cleanup")
    XCTAssertNil(coordinator.admit(.finalize), "replacement open owns the coordinator")
    coordinator.settle(open, succeeded: false)
    XCTAssertNil(coordinator.document, "failed replacement leaves the view empty")

    coordinator.dispose()
    coordinator.pdfQueue.sync {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.output.path))
    XCTAssertFalse(coordinator.isCurrent(finalize))
  }

  func testMutablePageOrderPreservesIdentityAndSelection() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    let appendedFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      appendedFixture.view.dispose(); appendedFixture.window.isHidden = true
    }
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let ids = state.pages.map(\.id)
    let appended = try XCTUnwrap(appendedFixture.view.documentCoordinator.document?.pages.first)

    let moveToEnd = try InkSignPdfDocumentCoordinator.pageOrder(
      current: state.pages, activePageID: ids[1], mutation: .moveActive(to: 2))
    XCTAssertEqual(moveToEnd.pages.map(\.id), [ids[0], ids[2], ids[1]])
    XCTAssertEqual(moveToEnd.activePageID, ids[1])
    XCTAssertTrue(moveToEnd.pages[2].history === state.pages[1].history)

    let noOp = try InkSignPdfDocumentCoordinator.pageOrder(
      current: moveToEnd.pages, activePageID: ids[1], mutation: .moveActive(to: 2))
    XCTAssertFalse(noOp.changed)
    XCTAssertEqual(noOp.pages.map(\.id), moveToEnd.pages.map(\.id))

    let removedLast = try InkSignPdfDocumentCoordinator.pageOrder(
      current: moveToEnd.pages, activePageID: ids[1], mutation: .removeActive)
    XCTAssertEqual(removedLast.pages.map(\.id), [ids[0], ids[2]])
    XCTAssertEqual(removedLast.activePageID, ids[2])
    XCTAssertTrue(removedLast.pages[1].history === state.pages[2].history)

    let removedMiddle = try InkSignPdfDocumentCoordinator.pageOrder(
      current: state.pages, activePageID: ids[1], mutation: .removeActive)
    XCTAssertEqual(removedMiddle.pages.map(\.id), [ids[0], ids[2]])
    XCTAssertEqual(removedMiddle.activePageID, ids[2])

    let appendedOrder = try InkSignPdfDocumentCoordinator.pageOrder(
      current: state.pages,
      activePageID: ids[1],
      mutation: .append([appended], activePageID: appended.id))
    XCTAssertEqual(appendedOrder.pages.map(\.id), ids + [appended.id])
    XCTAssertEqual(appendedOrder.activePageID, appended.id)
    XCTAssertEqual(appendedOrder.addedPageCount, 1)

    let keepCurrent = try InkSignPdfDocumentCoordinator.pageOrder(
      current: state.pages,
      activePageID: ids[1],
      mutation: .append([appended], activePageID: ids[1]))
    XCTAssertEqual(keepCurrent.activePageID, ids[1])

    XCTAssertThrowsError(try InkSignPdfDocumentCoordinator.pageOrder(
      current: [state.pages[0]], activePageID: ids[0], mutation: .removeActive)) { error in
      XCTAssertEqual(error as? InkSignPdfDocumentCoordinator.PageMutationError, .lastPageRequired)
    }
  }

  func testRejectedAndNoOpPageCommandsKeepActiveTextDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "draft"
    overlay.textViewDidChange(editor)
    let generation = view.documentCoordinator.generation

    _ = try view.removePage()
    _ = try view.movePage(pageIndex: 2)
    _ = try view.movePage(pageIndex: 0)

    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(view.documentCoordinator.document?.activePage.history.content.isEmpty == true)
    XCTAssertEqual(view.documentCoordinator.generation, generation)
  }

  func testCancelledPickerKeepsActiveTextDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    view.pageInputCoordinator = InkSignPdfPageInputCoordinator(
      hostView: view.container,
      artifactPolicy: view.artifactPolicy,
      presenterProvider: { fixture.window.rootViewController },
      controllerPresenter: { _, _ in },
      sourceChooser: { _, _ in UIViewController() })
    let overlay = view.textInteractionOverlay
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "draft"
    overlay.textViewDidChange(editor)
    let generation = view.documentCoordinator.generation

    _ = try view.addPages(options: nil)
    view.pageInputCoordinator.cancelPending()

    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(view.documentCoordinator.document?.activePage.history.content.isEmpty == true)
    XCTAssertEqual(view.documentCoordinator.generation, generation)
  }

  func testAddPagesWithEmptySourceListReturnsWithoutPublishingAMutation() throws {
    let fixture = makeFixture(pageCount: 2, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let generation = coordinator.generation
    let completed = expectation(description: "empty staging resolves")
    var result: AddPagesResult?
    var failure: Error?
    let promise = try view.addPages(options: AddPagesOptions(
      type: nil,
      sources: [],
      imagePageSize: nil,
      targetDpi: nil,
      jpegQuality: nil,
      activePage: nil))
    promise.then { result = $0; completed.fulfill() }
    promise.catch { failure = $0; completed.fulfill() }
    wait(for: [completed], timeout: 5)

    XCTAssertNil(failure)
    XCTAssertEqual(result?.addedPageCount, 0)
    XCTAssertEqual(try XCTUnwrap(result?.pageInfo).pageIndex, 1.0)
    XCTAssertTrue(coordinator.document === original)
    XCTAssertEqual(coordinator.generation, generation)
  }

  func testReplacementCancelsProductionPageInputStagingBeforePublication() throws {
    let fixture = makeFixture(pageCount: 1)
    let replacementFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      replacementFixture.view.dispose(); replacementFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let sourceURL = try XCTUnwrap(replacementFixture.view.documentCoordinator.document?.workingURL)
    let stagingStarted = DispatchSemaphore(value: 0)
    let releaseStaging = DispatchSemaphore(value: 0)
    defer { releaseStaging.signal() }
    view.pageInputCoordinator = InkSignPdfPageInputCoordinator(
      hostView: view.container,
      artifactPolicy: view.artifactPolicy,
      securityScope: { _, copy in
        stagingStarted.signal()
        _ = releaseStaging.wait(timeout: .now() + 5)
        return try copy()
      })

    let addPages = try view.addPages(options: AddPagesOptions(
      type: .pdf,
      sources: [sourceURL.path],
      imagePageSize: nil,
      targetDpi: nil,
      jpegQuality: nil,
      activePage: nil))
    let addPagesCancelled = expectation(description: "page input cancellation settles promptly")
    var addPagesError: Error?
    var addPagesRejectionCount = 0
    addPages.catch { error in
      addPagesError = error
      addPagesRejectionCount += 1
      addPagesCancelled.fulfill()
    }
    XCTAssertEqual(stagingStarted.wait(timeout: .now() + 2), .success)

    let replacement = Promise<PageInfo>()
    let replacementInstalled = expectation(description: "replacement installs after staged input cleanup")
    replacement.then { _ in replacementInstalled.fulfill() }
    replacement.catch { error in XCTFail("replacement failed: \(error)") }
    view.beginLoad(sourceURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: replacement)

    XCTAssertNil(coordinator.document)
    wait(for: [addPagesCancelled], timeout: 2)
    XCTAssertTrue(addPagesError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertEqual(addPagesRejectionCount, 1)
    releaseStaging.signal()
    wait(for: [replacementInstalled], timeout: 5)
    XCTAssertEqual(addPagesRejectionCount, 1)
    XCTAssertEqual(coordinator.document?.pages.count, 1)
  }

  func testMixedAddPagesAppliesEncodingOptionsOnlyToImageInputs() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }

    let pdfURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfMixed-\(UUID().uuidString).pdf")
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignImageMixed-\(UUID().uuidString).jpg")
    defer {
      try? FileManager.default.removeItem(at: pdfURL)
      try? FileManager.default.removeItem(at: imageURL)
    }

    let importedPdf = PDFDocument()
    let pdfImage = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 45)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 90, height: 45))
    }
    let pdfPage = try XCTUnwrap(PDFPage(image: pdfImage))
    pdfPage.setBounds(CGRect(x: 0, y: 0, width: 90, height: 45), for: .mediaBox)
    importedPdf.insert(pdfPage, at: 0)
    XCTAssertTrue(importedPdf.write(to: pdfURL))

    let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
    }
    try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: imageURL)

    let options = AddPagesOptions(
      type: nil,
      sources: [pdfURL.path, imageURL.path],
      imagePageSize: ImagePageSize(width: 144, height: 72),
      targetDpi: 72,
      jpegQuality: 0.1,
      activePage: nil)
    let completed = expectation(description: "mixed addPages")
    var result: AddPagesResult?
    var failure: Error?
    let promise = try fixture.view.addPages(options: options)
    promise.then { result = $0; completed.fulfill() }
    promise.catch { failure = $0; completed.fulfill() }
    wait(for: [completed], timeout: 30)

    if let failure { XCTFail("mixed addPages failed: \(failure)") }
    XCTAssertEqual(result?.addedPageCount, 2.0)
    let pages = try XCTUnwrap(fixture.view.documentCoordinator.document?.pages)
    XCTAssertEqual(pages.count, 3)
    XCTAssertEqual(pages[1].geometry.mediaBox.width, 90, accuracy: 0.01)
    XCTAssertEqual(pages[1].geometry.mediaBox.height, 45, accuracy: 0.01)
    XCTAssertEqual(pages[2].geometry.mediaBox.width, 144, accuracy: 0.01)
    XCTAssertEqual(pages[2].geometry.mediaBox.height, 72, accuracy: 0.01)
  }

  func testAddPagesSelectsRequestedImportedPageAndReturnsIt() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }

    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfActivePage-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let source = PDFDocument()
    for (index, width) in [111, 222].enumerated() {
      let size = CGSize(width: width, height: width + 20)
      let image = UIGraphicsImageRenderer(size: size).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
      }
      let page = try XCTUnwrap(PDFPage(image: image))
      page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
      source.insert(page, at: index)
    }
    XCTAssertTrue(source.write(to: sourceURL))

    func append(_ activePage: AddPagesActivePage?) throws -> AddPagesResult {
      let selection = activePage?.stringValue ?? "omitted"
      let completed = expectation(description: "append pages selecting \(selection)")
      var result: AddPagesResult?
      var failure: Error?
      let promise = try fixture.view.addPages(options: AddPagesOptions(
        type: .pdf,
        sources: [sourceURL.path],
        imagePageSize: nil,
        targetDpi: nil,
        jpegQuality: nil,
        activePage: activePage))
      promise.then { result = $0; completed.fulfill() }
      promise.catch { failure = $0; completed.fulfill() }
      wait(for: [completed], timeout: 30)
      if let failure { throw failure }
      return try XCTUnwrap(result)
    }

    let originalActiveID = try XCTUnwrap(fixture.view.documentCoordinator.document).activePageID
    let omittedResult = try append(nil)
    let afterCurrent = try XCTUnwrap(fixture.view.documentCoordinator.document)
    XCTAssertEqual(afterCurrent.activePageID, originalActiveID)
    XCTAssertEqual(afterCurrent.activePageIndex, 1)
    XCTAssertEqual(omittedResult.pageInfo?.pageIndex, 1)
    XCTAssertEqual(omittedResult.pageInfo?.pageCount, 5)

    let currentResult = try append(.current)
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePageID, originalActiveID)
    XCTAssertEqual(currentResult.pageInfo?.pageIndex, 1)
    XCTAssertEqual(currentResult.pageInfo?.pageCount, 7)

    let firstResult = try append(.firstadded)
    let afterFirst = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let firstInfo = try XCTUnwrap(firstResult.pageInfo)
    XCTAssertEqual(afterFirst.activePageIndex, 7)
    XCTAssertEqual(firstInfo.pageIndex, 7)
    XCTAssertEqual(firstInfo.width, 111, accuracy: 0.01)

    let lastResult = try append(.lastadded)
    let afterLast = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let lastInfo = try XCTUnwrap(lastResult.pageInfo)
    XCTAssertEqual(afterLast.activePageIndex, 10)
    XCTAssertEqual(lastInfo.pageIndex, 10)
    XCTAssertEqual(lastInfo.width, 222, accuracy: 0.01)
    XCTAssertEqual(lastInfo.pageCount, 11)
    XCTAssertTrue(fixture.view.documentView.currentPage === afterLast.activePage.page)

    let creationView = InkSignView()
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(creationView.view)
    creationView.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    defer { creationView.dispose(); window.isHidden = true }
    let created = expectation(description: "create document with current selection")
    var createdResult: AddPagesResult?
    var creationFailure: Error?
    let createPromise = try creationView.addPages(options: AddPagesOptions(
      type: .pdf,
      sources: [sourceURL.path],
      imagePageSize: nil,
      targetDpi: nil,
      jpegQuality: nil,
      activePage: .current))
    createPromise.then { createdResult = $0; created.fulfill() }
    createPromise.catch { creationFailure = $0; created.fulfill() }
    wait(for: [created], timeout: 30)
    if let creationFailure { throw creationFailure }
    let createdDocument = try XCTUnwrap(creationView.documentCoordinator.document)
    XCTAssertEqual(createdDocument.activePageIndex, 0)
    XCTAssertEqual(createdResult?.pageInfo?.pageIndex, 0)
    XCTAssertTrue(creationView.documentView.currentPage === createdDocument.activePage.page)

    let lastCreationView = InkSignView()
    let lastCreationController = UIViewController()
    let lastCreationWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    lastCreationWindow.rootViewController = lastCreationController
    lastCreationController.view.addSubview(lastCreationView.view)
    lastCreationView.view.frame = lastCreationController.view.bounds
    lastCreationWindow.makeKeyAndVisible()
    lastCreationController.view.layoutIfNeeded()
    defer { lastCreationView.dispose(); lastCreationWindow.isHidden = true }
    let lastCreated = expectation(description: "create document selecting last added page")
    var lastCreatedResult: AddPagesResult?
    var lastCreationFailure: Error?
    let lastCreatePromise = try lastCreationView.addPages(options: AddPagesOptions(
      type: .pdf,
      sources: [sourceURL.path],
      imagePageSize: nil,
      targetDpi: nil,
      jpegQuality: nil,
      activePage: .lastadded))
    lastCreatePromise.then { lastCreatedResult = $0; lastCreated.fulfill() }
    lastCreatePromise.catch { lastCreationFailure = $0; lastCreated.fulfill() }
    wait(for: [lastCreated], timeout: 30)
    if let lastCreationFailure { throw lastCreationFailure }
    let lastCreatedDocument = try XCTUnwrap(lastCreationView.documentCoordinator.document)
    let lastCreationInfo = try XCTUnwrap(lastCreatedResult?.pageInfo)
    XCTAssertEqual(lastCreatedDocument.activePageIndex, 1)
    XCTAssertEqual(lastCreationInfo.pageIndex, 1)
    XCTAssertEqual(lastCreationInfo.width, 222, accuracy: 0.01)
    XCTAssertTrue(lastCreationView.documentView.currentPage === lastCreatedDocument.activePage.page)
  }

  func testMoveAndRemoveCommandsPublishFinalPageOrder() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let movedID = original.activePageID
    let annotation = makeCenteredTextAnnotation(
      id: 12, text: "kept", fontSize: 18,
      pageSize: original.activePage.geometry.mediaBox.size)
    XCTAssertTrue(original.activePage.history.appendText(annotation))

    let moved = expectation(description: "move page")
    let move = try view.movePage(pageIndex: 0)
    move.then { _ in moved.fulfill() }
    move.catch { error in XCTFail("move failed: \(error)"); moved.fulfill() }
    wait(for: [moved], timeout: 30)

    let afterMove = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(afterMove.pages.map(\.geometry.mediaBox.width), [400, 300, 500])
    XCTAssertEqual(afterMove.activePageID, movedID)
    XCTAssertEqual(afterMove.activePage.history.content.textAnnotations.first?.text, "kept")

    let removed = expectation(description: "remove page")
    let remove = try view.removePage()
    remove.then { _ in removed.fulfill() }
    remove.catch { error in XCTFail("remove failed: \(error)"); removed.fulfill() }
    wait(for: [removed], timeout: 30)

    let afterRemove = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(afterRemove.pages.map(\.geometry.mediaBox.width), [300, 500])
    XCTAssertEqual(afterRemove.activePageIndex, 0)
    XCTAssertEqual(afterRemove.document.pageCount, 2)
    XCTAssertEqual(afterRemove.document.page(at: 0)?.rotation, 0)
    XCTAssertEqual(afterRemove.document.page(at: 1)?.rotation, 0)
    let workingPdf = try XCTUnwrap(CGPDFDocument(afterRemove.workingURL as CFURL),
                                   "the published working PDF must remain readable by the exporter")
    XCTAssertEqual(workingPdf.numberOfPages, 2)
    XCTAssertEqual(try XCTUnwrap(workingPdf.page(at: 1)).getBoxRect(.mediaBox).width,
                   300, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(workingPdf.page(at: 1)).getBoxRect(.mediaBox).height,
                   400, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(workingPdf.page(at: 2)).getBoxRect(.mediaBox).width,
                   500, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(workingPdf.page(at: 2)).getBoxRect(.mediaBox).height,
                   400, accuracy: 0.5)

    let exported = expectation(description: "export page order")
    let output = try view.finalize()
    output.then { path in
      let outputURL = URL(string: path)!
      let pdf = PDFDocument(url: outputURL)
      XCTAssertEqual(pdf?.pageCount, 2)
      XCTAssertEqual(pdf?.page(at: 0)?.bounds(for: .mediaBox).width, 300)
      XCTAssertEqual(pdf?.page(at: 0)?.bounds(for: .mediaBox).height, 400)
      XCTAssertEqual(pdf?.page(at: 1)?.bounds(for: .mediaBox).width, 500)
      XCTAssertEqual(pdf?.page(at: 1)?.bounds(for: .mediaBox).height, 400)
      if let data = try? Data(contentsOf: outputURL) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "native-ios-reordered-export.pdf"
        attachment.lifetime = .keepAlways
        self.add(attachment)
      } else {
        XCTFail("The finalized reordered PDF must be readable for independent inspection.")
      }
      exported.fulfill()
    }
    output.catch { error in XCTFail("export failed: \(error)"); exported.fulfill() }
    wait(for: [exported], timeout: 30)
  }

  func testRotatePagePreservesHistoryAndExportsPageRotation() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let document = try XCTUnwrap(view.documentCoordinator.document)
    let page = document.activePage
    let pageID = page.id

    let point = PKStrokePoint(location: CGPoint(x: 35, y: 55),
                              timeOffset: 0,
                              size: CGSize(width: 5, height: 5),
                              opacity: 1,
                              force: 0.5,
                              azimuth: 0,
                              altitude: .pi / 2)
    let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                          path: PKStrokePath(controlPoints: [point], creationDate: Date()),
                          transform: .identity,
                          mask: nil)
    _ = try appendTextAnnotationForTest(InkSignPdfTextAnnotation(id: 13,
                                        text: "Approved",
                                        bounds: CGRect(x: 45, y: 95, width: 150, height: 24),
                                        fontSize: 18,
                                        textColor: "#008000",
                                        isRTL: false), in: view, pageIndex: 0)
    let beforeInk = page.history.content
    XCTAssertTrue(page.history.record(type: .ink,
                                      before: beforeInk,
                                      after: beforeInk.replacingDrawing(PKDrawing(strokes: [stroke]))))
    XCTAssertTrue(page.history.undo())
    let historyStateBefore = page.history.state
    let contentBefore = page.history.content
    XCTAssertTrue(historyStateBefore.canUndo)
    XCTAssertTrue(historyStateBefore.canRedo)

    let workingURLBefore = try XCTUnwrap(view.documentCoordinator.document?.workingURL)
    let workingBytesBefore = try Data(contentsOf: workingURLBefore)
    try awaitModeChange(view.setInkMode(viewport: nil))
    let rotated = expectation(description: "rotate page")
    var rotatedInfo: PageInfo?
    var rotationError: Error?
    let rotation = try view.rotatePage(degrees: 90)
    rotation.then { rotatedInfo = $0; rotated.fulfill() }
    rotation.catch { rotationError = $0; rotated.fulfill() }
    wait(for: [rotated], timeout: 30)

    XCTAssertNil(rotationError)
    let pageInfo = try XCTUnwrap(rotatedInfo)
    XCTAssertEqual(pageInfo.width, 400, accuracy: 0.01)
    XCTAssertEqual(pageInfo.height, 300, accuracy: 0.01)
    let afterRotation = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(view.attachedOverlayPage, pageID)
    XCTAssertTrue(view.overlayProvider.isDisplaying(afterRotation.activePage.page))
    XCTAssertTrue(view.canvasView === view.overlayProvider.canvasView(for: pageID))
    XCTAssertTrue(view.documentView.isUserInteractionEnabled)
    XCTAssertTrue(view.canvasView.drawingGestureRecognizer.isEnabled)
    XCTAssertTrue(view.editMode)
    XCTAssertEqual(afterRotation.workingURL, workingURLBefore)
    XCTAssertEqual(try Data(contentsOf: afterRotation.workingURL), workingBytesBefore)
    XCTAssertEqual(afterRotation.activePage.sourceGeometry.rotation, 0)
    XCTAssertEqual(afterRotation.pages.map(\.id), [pageID])
    XCTAssertEqual(afterRotation.activePage.geometry.rotation, 90)
    XCTAssertEqual(afterRotation.activePage.geometryRevision, 1)
    XCTAssertEqual(afterRotation.activePage.history.state.canUndo, historyStateBefore.canUndo)
    XCTAssertEqual(afterRotation.activePage.history.state.canRedo, historyStateBefore.canRedo)
    XCTAssertTrue(afterRotation.activePage.history.content.equals(contentBefore))

    // Assembly reads the unchanged source, then rebinds pending orientation.
    _ = try awaitRotationOperation(view.addPages(options: AddPagesOptions(
      type: .pdf, sources: [workingURLBefore.path], imagePageSize: nil,
      targetDpi: nil, jpegQuality: nil, activePage: nil)))
    XCTAssertEqual(view.documentCoordinator.document?.activePageID, pageID)
    XCTAssertEqual(view.documentCoordinator.document?.activePage.geometry.rotation, 90)
    _ = try awaitRotationOperation(view.movePage(pageIndex: 1))
    let afterMove = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(afterMove.pages[1].id, pageID)
    XCTAssertTrue(afterMove.pages[1].history === page.history)
    XCTAssertTrue(afterMove.pages[1].history.content.equals(contentBefore))
    XCTAssertTrue(afterMove.pages[1].history.state.canRedo)
    // Select the appended page for removal; the rotated page must survive.
    XCTAssertTrue(view.documentCoordinator.selectPage(at: 0))
    _ = try awaitRotationOperation(view.removePage())
    let afterAssembly = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(afterAssembly.pages.map(\.id), [pageID])
    XCTAssertEqual(afterAssembly.activePage.geometry.rotation, 90)
    XCTAssertEqual(afterAssembly.activePage.sourceGeometry.rotation, 0)
    XCTAssertTrue(afterAssembly.activePage.history === page.history)
    XCTAssertTrue(afterAssembly.activePage.history.content.equals(contentBefore))
    XCTAssertTrue(afterAssembly.activePage.history.state.canRedo)

    try view.redo()
    view.defaultTextColor = "#D00000"
    drainMainQueue()
    try insertTextForTest("New text",
      bounds: TextAnnotationBounds(x: 60, y: 160, width: 160, height: 24),
      options: nil, in: view)

    let exported = expectation(description: "export rotated PDF")
    var outputURL: URL?
    var exportError: Error?
    let output = try view.finalize()
    output.then { path in outputURL = URL(string: path)!; exported.fulfill() }
    output.catch { error in exportError = error; exported.fulfill() }
    wait(for: [exported], timeout: 30)
    XCTAssertNil(exportError)
    let reopenedURL = try XCTUnwrap(outputURL)
    let reopened = try XCTUnwrap(PDFDocument(url: reopenedURL))
    XCTAssertEqual(reopened.pageCount, 1)
    XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
    XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.contents == "Approved" } == true)
    XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.contents == "New text" } == true)
    let renderedPage = try XCTUnwrap(reopened.page(at: 0))
    let oldTextPixels = try rotationPixelBounds(in: renderedPage) { red, green, blue in
      Int(green) > Int(red) + 40 && Int(green) > Int(blue) + 40
    }
    XCTAssertTrue(CGRect(x: 279, y: 43, width: 28, height: 154).contains(oldTextPixels),
                  "Existing text must rotate with its source-page position")
    let inkPixels = try rotationPixelBounds(in: renderedPage) { red, green, blue in
      red < 100 && green < 100 && blue < 100
    }
    XCTAssertTrue(CGRect(x: 335, y: 25, width: 20, height: 20).contains(inkPixels),
                  "Committed ink must rotate with the page")
    let newTextPixels = try rotationPixelBounds(in: renderedPage) { red, green, blue in
      Int(red) > Int(green) + 60 && Int(red) > Int(blue) + 60
    }
    XCTAssertTrue(CGRect(x: 58, y: 158, width: 164, height: 28).contains(newTextPixels),
                  "New text must remain inside its displayed insertion rectangle")
    XCTAssertGreaterThan(newTextPixels.width, newTextPixels.height,
                         "This single-line insertion must remain upright")
    XCTAssertFalse(try XCTUnwrap(view.documentCoordinator.document).activePage.history.content.drawing.strokes.isEmpty)
    for _ in 0..<3 {
      let completed = expectation(description: "compose quarter turn")
      let next = try view.rotatePage(degrees: 90)
      next.then { _ in completed.fulfill() }
      next.catch { error in XCTFail("composed rotation failed: \(error)"); completed.fulfill() }
      wait(for: [completed], timeout: 30)
    }
    let restored = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(restored.activePage.geometry.rotation, 0)
    XCTAssertEqual(restored.activePage.geometry.displaySize, CGSize(width: 300, height: 400))
    XCTAssertEqual(restored.activePage.geometryRevision, 4)
    try? outputURL.map { try FileManager.default.removeItem(at: $0) }
  }

  func testFieldCommandsUseDisplayedGeometryThroughQuarterTurns() throws {
    let fixture = makeFixture(pageCount: 1)
    let view = fixture.view
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("RotatedFields-\(UUID().uuidString).pdf")
    defer {
      try? FileManager.default.removeItem(at: url)
      view.dispose(); fixture.window.isHidden = true
    }
    try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).writePDF(to: url) { renderer in
      renderer.beginPage()
      NSAttributedString(string: "Name", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        .draw(at: CGPoint(x: 140, y: 116))
      renderer.cgContext.setLineWidth(1)
      for (left, right) in [(20.0, 110.0), (210.0, 280.0)] {
        renderer.cgContext.move(to: CGPoint(x: left, y: 132))
        renderer.cgContext.addLine(to: CGPoint(x: right, y: 132))
        renderer.cgContext.strokePath()
      }
    }
    _ = try awaitRotationOperation(view.open(path: url.path, options: nil))
    view.defaultTextColor = "#D00000"
    drainMainQueue()
    for angle in [0, 90, 180, 270] {
      if angle != 0 { _ = try awaitRotationOperation(view.rotatePage(degrees: 90)) }
      let state = try XCTUnwrap(view.documentCoordinator.document)
      let historyBefore = state.activePage.history.content
      let modeBefore = view.editMode
      let page = try awaitRotationOperation(view.getPage(pageIndex: nil))
      let textOptions = ResolveTextOptions(fieldName: "Name", bounds: nil, occurrence: nil,
        fontSize: nil, color: nil, direction: .ltr, maxLines: 2,
        alignment: nil, verticalAnchor: .bottom)
      if angle == 90 || angle == 270 {
        do {
          _ = try page.resolveText(options: textOptions)
          XCTFail("A vertical rule must not accept field insertion")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("text_rule_not_found")) }
        XCTAssertTrue(state.activePage.history.content.equals(historyBefore))
        XCTAssertEqual(view.editMode, modeBefore)
        continue
      }
      let textID = try page.resolveText(options: textOptions)
      try page.setTextValue(id: textID, text: "OK")
      let annotation = try XCTUnwrap(state.activePage.history.content.textAnnotations.last)
      let ruleY: CGFloat = angle == 0 ? 132 : 268
      let field = CGRect(x: angle == 0 ? 210 : 190, y: 0,
                         width: angle == 0 ? 70 : 90, height: ruleY)
      XCTAssertEqual(annotation.flowBounds, field)
      XCTAssertEqual(annotation.layoutRotation, angle)
      XCTAssertLessThanOrEqual(annotation.bounds.maxY, ruleY)
      for anchor in [FieldFocusVerticalAnchor.top, .bottom] {
        _ = try awaitRotationOperation(page.focusText(id: textID,
          options: FieldFocusOptions(occurrence: nil, direction: .ltr, zoom: 5,
                                     verticalAnchor: anchor, edgeOffset: 8, setInkMode: false)))
        view.documentView.layoutIfNeeded()
        let viewport = view.documentView.bounds
        let pdfCenter = view.documentView.convert(CGPoint(x: viewport.midX, y: viewport.midY),
                                                   to: state.activePage.page)
        var displayedCenter = pdfCenter.applying(
          state.activePage.geometry.displayToPDFTransform.inverted())
        let pdfTopLeft = view.documentView.convert(
          CGPoint(x: viewport.minX, y: viewport.minY), to: state.activePage.page)
        var displayedTopLeft = pdfTopLeft.applying(
          state.activePage.geometry.displayToPDFTransform.inverted())
        let halfHeight = viewport.height / (2 * view.documentView.scaleFactor)
        let expectedY = anchor == .top ? ruleY + halfHeight - 8 : ruleY - halfHeight + 8
        let clampedY = min(max(expectedY, halfHeight), 400 - halfHeight)
        let settleDeadline = Date().addingTimeInterval(1)
        while abs(displayedCenter.y - clampedY) > 2 && Date() < settleDeadline {
          RunLoop.main.run(until: Date().addingTimeInterval(0.025))
          view.documentView.layoutIfNeeded()
          let settledViewport = view.documentView.bounds
          let settledPDFCenter = view.documentView.convert(
            CGPoint(x: settledViewport.midX, y: settledViewport.midY),
            to: state.activePage.page)
          displayedCenter = settledPDFCenter.applying(
            state.activePage.geometry.displayToPDFTransform.inverted())
          let settledPDFTopLeft = view.documentView.convert(
            CGPoint(x: settledViewport.minX, y: settledViewport.minY),
            to: state.activePage.page)
          displayedTopLeft = settledPDFTopLeft.applying(
            state.activePage.geometry.displayToPDFTransform.inverted())
        }
        XCTAssertEqual(displayedCenter.y, clampedY, accuracy: 2,
          "rotation=\(angle), anchor=\(anchor), zoom=\(view.documentView.scaleFactor), " +
          "requestedCenter=\(clampedY), visibleTopLeft=\(displayedTopLeft), halfHeight=\(halfHeight), " +
          "destination=\(String(describing: view.documentView.currentDestination?.point))")
      }
      let output = try awaitRotationOperation(view.finalize())
      defer { try? FileManager.default.removeItem(atPath: output) }
      let exported = try XCTUnwrap(PDFDocument(url: URL(string: output)!))
      let pixels = try rotationPixelBounds(in: XCTUnwrap(exported.page(at: 0))) { red, green, blue in
        Int(red) > Int(green) + 60 && Int(red) > Int(blue) + 60
      }
      // Only this insertion remains red in the following iteration.
      XCTAssertTrue(field.insetBy(dx: -2, dy: -2).contains(pixels))
      XCTAssertGreaterThan(pixels.width, pixels.height)
      try view.clear()
    }
  }

  private func awaitRotationOperation<T>(_ promise: Promise<T>) throws -> T {
    let completed = expectation(description: "rotation page assembly settles")
    var result: T?
    var failure: Error?
    promise.then { result = $0; completed.fulfill() }
    promise.catch { failure = $0; completed.fulfill() }
    wait(for: [completed], timeout: 30)
    if let failure { throw failure }
    return try XCTUnwrap(result)
  }

  /// Measures all pixels of one fixture color, including any outside its field.
  private func rotationPixelBounds(in page: PDFPage,
                                   matches: (UInt8, UInt8, UInt8) -> Bool) throws -> CGRect {
    let size = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation).displaySize
    let width = Int(size.width.rounded())
    let height = Int(size.height.rounded())
    let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: CGFloat(width), height: CGFloat(height)),
                                           for: .mediaBox).cgImage)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(CGContext(
        data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }
    var left = width, top = height, right = -1, bottom = -1
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        if bytes[offset + 3] > 0 && matches(bytes[offset], bytes[offset + 1], bytes[offset + 2]) {
          left = min(left, x); top = min(top, y)
          right = max(right, x); bottom = max(bottom, y)
        }
      }
    }
    XCTAssertGreaterThanOrEqual(right, left, "Expected visible fixture pixels")
    XCTAssertGreaterThanOrEqual(bottom, top, "Expected visible fixture pixels")
    return CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(max(0, right - left + 1)),
                  height: CGFloat(max(0, bottom - top + 1)))
  }

  func testStructuralPublicationIsAtomicAndRejectsStaleCandidate() throws {
    let fixture = makeFixture(pageCount: 2)
    let candidateFixture = makeFixture(pageCount: 3, activePageIndex: 2)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      candidateFixture.view.dispose(); candidateFixture.window.isHidden = true
    }
    let coordinator = fixture.view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let fixtureCandidate = try XCTUnwrap(candidateFixture.view.documentCoordinator.document)
    let candidateData = try Data(contentsOf: fixtureCandidate.workingURL)
    let candidateURL = try coordinator.artifactPolicy.allocateWorkingSource()
    try candidateData.write(to: candidateURL, options: .atomic)
    let loadedCandidate = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidatePages = try fixtureCandidate.pages.enumerated().map { index, old in
      InkSignPdfDocumentCandidateLoader.rebinding(old, to: loadedCandidate.pages[index])
    }
    let candidate = InkSignPdfDocumentState(sourceURL: fixtureCandidate.sourceURL,
                                            workingURL: candidateURL,
                                            document: loadedCandidate.document,
                                            pages: candidatePages,
                                            activePageID: fixtureCandidate.activePageID)
    defer {
      if coordinator.document !== candidate {
        coordinator.artifactPolicy.deleteExact(candidateURL)
      }
    }
    let operation = try XCTUnwrap(coordinator.admit(.structural))

    XCTAssertTrue(coordinator.publishStructural(candidate, operation: operation) === original)
    XCTAssertTrue(coordinator.document === candidate)
    XCTAssertTrue(coordinator.structuralDirty)
    coordinator.settle(operation, succeeded: true)

    let staleCandidate = try XCTUnwrap(candidateFixture.view.documentCoordinator.document)
    let staleOperation = try XCTUnwrap(coordinator.admit(.structural))
    _ = coordinator.nextGeneration()
    XCTAssertNil(coordinator.publishStructural(staleCandidate, operation: staleOperation))
    XCTAssertTrue(coordinator.document === candidate)
    coordinator.settle(staleOperation, succeeded: false)
  }

  func testCoordinatorCanPublishTheFirstAddedDocument() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let source = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let data = try Data(contentsOf: source.workingURL)
    let artifacts = InkSignPdfCacheArtifactPolicy.shared
    let candidateURL = try artifacts.allocateWorkingSource()
    defer { artifacts.deleteExact(candidateURL) }
    try data.write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = InkSignPdfDocumentState(sourceURL: candidateURL,
                                            workingURL: candidateURL,
                                            document: loaded.document,
                                            pages: loaded.pages)
    let coordinator = InkSignPdfDocumentCoordinator(artifactPolicy: artifacts)
    defer { coordinator.dispose() }
    let operation = try XCTUnwrap(coordinator.admit(.structural))

    XCTAssertTrue(coordinator.publishInitialStructural(candidate, operation: operation))
    XCTAssertTrue(coordinator.document === candidate)
    XCTAssertEqual(coordinator.document?.pages.count, 1)
    XCTAssertTrue(coordinator.structuralDirty)
    coordinator.settle(operation, succeeded: true)
  }

  func testOpenCancelsStructuralAdmissionAndDeletesPendingArtifacts() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let coordinator = fixture.view.documentCoordinator
    let structural = try XCTUnwrap(coordinator.admit(.structural))
    let staged = try coordinator.artifactPolicy.allocateWorkingSource()
    XCTAssertTrue(coordinator.registerPendingArtifact(staged, for: structural))

    let open = try XCTUnwrap(coordinator.admit(.open))

    XCTAssertFalse(coordinator.isCurrent(structural))
    let artifactRemoved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: staged.path) },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [artifactRemoved], timeout: 5), .completed)
    coordinator.settle(structural, succeeded: false)
    coordinator.settle(open, succeeded: false)
    XCTAssertNil(coordinator.document)
  }

  func testReplacementOpenCancelsPendingOpen() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let firstOperation = try XCTUnwrap(view.documentCoordinator.admit(.open))
    let firstPromise = Promise<PageInfo>()
    var firstError: Error?
    firstPromise.catch { firstError = $0 }
    view.pendingOpen = InkSignView.PendingOpen(operation: firstOperation,
                                               promise: firstPromise,
                                               zoom: nil,
                                               focus: nil,
                                               fitToPage: true)

    view.beginLoad("", zoom: nil, focus: nil, fitToPage: true,
                   promise: Promise<PageInfo>())

    XCTAssertNotNil(firstError)
    XCTAssertNotNil(view.pendingOpen)
    XCTAssertNotEqual(view.pendingOpen?.operation.generation, firstOperation.generation)
    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertFalse(view.documentCoordinator.isCurrent(firstOperation))
  }

  func testProductionTextLookupCommitsToCapturedPageAfterNavigation() throws {
    let fixture = makeFixture(pageCount: 1)
    let keyPDFURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignCapturedPageKey-\(UUID().uuidString).pdf")
    defer {
      try? FileManager.default.removeItem(at: keyPDFURL)
      fixture.view.dispose(); fixture.window.isHidden = true
    }

    let pageBounds = CGRect(x: 0, y: 0, width: 300, height: 400)
    let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
    try renderer.writePDF(to: keyPDFURL) { context in
      context.beginPage()
      NSAttributedString(string: "Name",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 70, y: 120))
      context.cgContext.setStrokeColor(UIColor.black.cgColor)
      context.cgContext.setLineWidth(1)
      context.cgContext.move(to: CGPoint(x: 70, y: 131))
      context.cgContext.addLine(to: CGPoint(x: 250, y: 131))
      context.cgContext.strokePath()
      context.beginPage()
    }

    let view = fixture.view
    let coordinator = view.documentCoordinator
    let opened = expectation(description: "two-page key fixture opens")
    let openPromise = Promise<PageInfo>()
    openPromise.then { _ in opened.fulfill() }
    openPromise.catch { error in XCTFail("key fixture failed to open: \(error)") }
    view.beginLoad(keyPDFURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: openPromise)
    wait(for: [opened], timeout: 5)
    XCTAssertEqual(coordinator.document?.pages.count, 2)
    let keyPage = try XCTUnwrap(coordinator.document?.pages.first)
    let analysis = InkSignPdfPageAnalysis.build(generation: coordinator.generation,
                                                pageID: keyPage.id,
                                                pageIndex: 0,
                                                page: keyPage.page,
                                                mediaBox: keyPage.geometry.mediaBox)
    let lookup = analysis.lookup(key: "Name")
    XCTAssertTrue(lookup.hasLiteralMatch)
    let displayed = analysis.displayedFieldGeometry(lookup: lookup, geometry: keyPage.geometry)
    XCTAssertNotNil(InkSignPdfKeyRuleSelector.select(
      matches: displayed.matches,
      rules: displayed.rules,
      occurrence: .first,
      directionRtl: view.textInteractionOverlay.resolvedDirection(nil),
      pageSize: keyPage.geometry.displaySize),
      "Fixture must contain a usable same-row rule; matches=\(displayed.matches), rules=\(displayed.rules)")

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let pageRequest = try view.getPage(pageIndex: 0)

    XCTAssertEqual(try view.switchPage(to: 1).pageIndex, 1)
    XCTAssertEqual(coordinator.document?.activePageIndex, 1)
    releaseWorker.signal()
    let page = try awaitRotationOperation(pageRequest)
    let textID = try page.resolveText(options: ResolveTextOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, fontSize: nil, color: nil,
      direction: nil, maxLines: nil, alignment: nil, verticalAnchor: nil))
    try page.setTextValue(id: textID, text: "filled")
    XCTAssertEqual(coordinator.document?.activePageIndex, 1)
    XCTAssertEqual(coordinator.document?.pages[0].history.content.textAnnotations.map(\.text), ["filled"])
    XCTAssertTrue(coordinator.document?.pages[1].history.content.textAnnotations.isEmpty == true)
  }

  func testPendingPreparedPageUsesCurrentGeometryAfterRotation() throws {
    let fixture = makeFixture(pageCount: 1)
    let keyPDFURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignRotationFieldLookup-\(UUID().uuidString).pdf")
    defer {
      try? FileManager.default.removeItem(at: keyPDFURL)
      fixture.view.dispose(); fixture.window.isHidden = true
    }
    try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
      .writePDF(to: keyPDFURL) { context in
        context.beginPage()
        NSAttributedString(string: "Name", attributes: [.font: UIFont.systemFont(ofSize: 18)])
          .draw(at: CGPoint(x: 70, y: 120))
        context.cgContext.setStrokeColor(UIColor.black.cgColor)
        context.cgContext.setLineWidth(1)
        context.cgContext.move(to: CGPoint(x: 70, y: 131))
        context.cgContext.addLine(to: CGPoint(x: 250, y: 131))
        context.cgContext.strokePath()
      }

    let view = fixture.view
    let opened = expectation(description: "rotation lookup fixture opens")
    var openError: Error?
    let open = Promise<PageInfo>()
    open.then { _ in opened.fulfill() }
    open.catch { error in openError = error; opened.fulfill() }
    view.beginLoad(keyPDFURL.path, zoom: nil, focus: nil, fitToPage: true, promise: open)
    wait(for: [opened], timeout: 10)
    XCTAssertNil(openError)
    view.documentCoordinator.pdfQueue.sync {}

    let workerHeld = expectation(description: "field worker is held before lookup")
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    view.documentCoordinator.pdfQueue.async {
      workerHeld.fulfill()
      _ = releaseWorker.wait(timeout: .now() + 30)
    }
    wait(for: [workerHeld], timeout: 5)

    let pageRequest = try view.getPage(pageIndex: nil)
    let rotated = expectation(description: "rotation follows prepared lookup")
    var completionOrder: [String] = []
    pageRequest.then { _ in completionOrder.append("prepared") }
    let rotation = try view.rotatePage(degrees: 90)
    var rotationError: Error?
    rotation.then { _ in completionOrder.append("rotated"); rotated.fulfill() }
    rotation.catch { error in rotationError = error; rotated.fulfill() }
    releaseWorker.signal()
    let page = try awaitRotationOperation(pageRequest)
    wait(for: [rotated], timeout: 10)

    XCTAssertNil(rotationError)
    XCTAssertEqual(completionOrder, ["prepared", "rotated"])
    let document = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(document.activePage.geometryRevision, 1)
    XCTAssertTrue(document.activePage.history.content.textAnnotations.isEmpty)
    XCTAssertThrowsError(try page.resolveText(options: ResolveTextOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, fontSize: nil, color: nil,
      direction: .ltr, maxLines: nil, alignment: nil, verticalAnchor: .bottom))) {
      XCTAssertTrue($0.localizedDescription.hasPrefix("text_rule_not_found"))
    }
  }

  func testPendingPreparedPageFocusRejectsVerticalRuleAfterRotation() throws {
    let fixture = makeFixture(pageCount: 1)
    let keyPDFURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignRotationFieldFocus-\(UUID().uuidString).pdf")
    defer {
      try? FileManager.default.removeItem(at: keyPDFURL)
      fixture.view.dispose(); fixture.window.isHidden = true
    }
    try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
      .writePDF(to: keyPDFURL) { context in
        context.beginPage()
        NSAttributedString(string: "Name", attributes: [.font: UIFont.systemFont(ofSize: 18)])
          .draw(at: CGPoint(x: 70, y: 120))
        context.cgContext.setStrokeColor(UIColor.black.cgColor)
        context.cgContext.setLineWidth(1)
        context.cgContext.move(to: CGPoint(x: 70, y: 131))
        context.cgContext.addLine(to: CGPoint(x: 250, y: 131))
        context.cgContext.strokePath()
      }

    let view = fixture.view
    let opened = expectation(description: "rotation focus fixture opens")
    var openError: Error?
    let open = Promise<PageInfo>()
    open.then { _ in opened.fulfill() }
    open.catch { error in openError = error; opened.fulfill() }
    view.beginLoad(keyPDFURL.path, zoom: nil, focus: nil, fitToPage: true, promise: open)
    wait(for: [opened], timeout: 10)
    XCTAssertNil(openError)
    view.documentCoordinator.pdfQueue.sync {}

    let workerHeld = expectation(description: "field worker is held before focus lookup")
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    view.documentCoordinator.pdfQueue.async {
      workerHeld.fulfill()
      _ = releaseWorker.wait(timeout: .now() + 30)
    }
    wait(for: [workerHeld], timeout: 5)

    let pageRequest = try view.getPage(pageIndex: nil)
    let rotated = expectation(description: "rotation follows prepared focus lookup")
    var completionOrder: [String] = []
    pageRequest.then { _ in completionOrder.append("prepared") }
    let rotation = try view.rotatePage(degrees: 90)
    var rotationError: Error?
    rotation.then { _ in completionOrder.append("rotated"); rotated.fulfill() }
    rotation.catch { error in rotationError = error; rotated.fulfill() }
    releaseWorker.signal()
    let page = try awaitRotationOperation(pageRequest)
    wait(for: [rotated], timeout: 10)

    XCTAssertNil(rotationError)
    XCTAssertEqual(completionOrder, ["prepared", "rotated"])
    XCTAssertEqual(view.documentCoordinator.document?.activePage.geometryRevision, 1)
    XCTAssertTrue(view.documentCoordinator.document?.activePage.history.content.textAnnotations.isEmpty == true)
    XCTAssertThrowsError(try page.resolveText(options: ResolveTextOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, fontSize: nil, color: nil,
      direction: .ltr, maxLines: nil, alignment: nil, verticalAnchor: nil))) {
      XCTAssertTrue($0.localizedDescription.hasPrefix("text_rule_not_found"))
    }
  }

  func testQueuedFocusAndModeExecuteInSubmissionOrder() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let page = try awaitRotationOperation(view.getPage(pageIndex: nil))
    let textID = try page.resolveText(options: ResolveTextOptions(
      fieldName: nil, bounds: TextAnnotationBounds(x: 50, y: 60, width: 100, height: 30),
      occurrence: nil, fontSize: nil, color: nil, direction: nil, maxLines: nil,
      alignment: nil, verticalAnchor: nil))
    var modes: [String] = []
    view.onStateChange = { modes.append($0.mode.stringValue) }
    let gate = Promise<Void>()
    let blocked = view.enqueueViewerCommand { gate }
    let focus = try page.focusText(id: textID,
      options: FieldFocusOptions(occurrence: nil, direction: nil, zoom: 3,
        verticalAnchor: nil, edgeOffset: nil, setInkMode: true))
    let textMode = try view.setTextMode(options: nil)
    XCTAssertFalse(view.editMode)
    XCTAssertFalse(view.textInteractionOverlay.hasPendingPlacement())

    gate.resolve()
    try awaitModeChange(blocked)
    try awaitModeChange(focus)
    try awaitModeChange(textMode)
    let inkIndex = try XCTUnwrap(modes.firstIndex(of: "ink"))
    let textIndex = try XCTUnwrap(modes.firstIndex(of: "textAdd"))
    XCTAssertLessThan(inkIndex, textIndex)
    XCTAssertTrue(view.textInteractionOverlay.hasPendingPlacement())
    XCTAssertFalse(view.editMode)
    XCTAssertEqual(try view.currentViewportSnapshot().zoom, 3, accuracy: 0.01)
    try awaitModeChange(view.setViewMode(viewport: nil))
    XCTAssertFalse(view.textInteractionOverlay.hasPendingPlacement())
    XCTAssertEqual(modes.last, "view")
  }

  func testReplacementCancelsProductionTextLookupAndIgnoresLateWorkerResult() throws {
    let fixture = makeFixture(pageCount: 1)
    let replacementFixture = makeFixture(pageCount: 1)
    let keyPDFURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignKeyLookup-\(UUID().uuidString).pdf")
    defer {
      try? FileManager.default.removeItem(at: keyPDFURL)
      fixture.view.dispose(); fixture.window.isHidden = true
      replacementFixture.view.dispose(); replacementFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let pageBounds = CGRect(x: 0, y: 0, width: 300, height: 400)
    let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
    try renderer.writePDF(to: keyPDFURL) { context in
      context.beginPage()
      NSAttributedString(string: "Name",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 70, y: 120))
    }
    let keyDocument = try XCTUnwrap(PDFDocument(url: keyPDFURL))
    let keyPage = try XCTUnwrap(keyDocument.page(at: 0))
    let keyAnalysis = InkSignPdfPageAnalysis.build(generation: 1,
                                                   pageID: UUID(),
                                                   pageIndex: 0,
                                                   page: keyPage,
                                                   mediaBox: keyPage.bounds(for: .mediaBox))
    XCTAssertTrue(keyAnalysis.lookup(key: "Name").hasLiteralMatch)

    let initialLoad = Promise<PageInfo>()
    let initialLoadCompleted = expectation(description: "PDF-backed key fixture opens")
    initialLoad.then { _ in initialLoadCompleted.fulfill() }
    initialLoad.catch { error in XCTFail("key fixture failed to open: \(error)") }
    view.beginLoad(keyPDFURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: initialLoad)
    wait(for: [initialLoadCompleted], timeout: 5)
    coordinator.pdfQueue.sync {}

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let lookup = try view.getPage(pageIndex: nil)
    let lookupCancelled = expectation(description: "prepared page cancellation settles promptly")
    var lookupError: Error?
    var lookupRejectionCount = 0
    lookup.catch { error in
      lookupError = error
      lookupRejectionCount += 1
      lookupCancelled.fulfill()
    }

    let replacement = Promise<PageInfo>()
    let replacementInstalled = expectation(description: "replacement installs after worker release")
    replacement.then { _ in replacementInstalled.fulfill() }
    replacement.catch { error in XCTFail("replacement failed: \(error)") }
    let replacementURL = try XCTUnwrap(replacementFixture.view.documentCoordinator.document?.workingURL)
    view.beginLoad(replacementURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: replacement)

    XCTAssertNil(coordinator.document)
    wait(for: [lookupCancelled], timeout: 2)
    XCTAssertTrue(lookupError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertEqual(lookupRejectionCount, 1)

    releaseWorker.signal()
    wait(for: [replacementInstalled], timeout: 5)
    coordinator.pdfQueue.sync {}
    XCTAssertEqual(lookupRejectionCount, 1)
    XCTAssertTrue(coordinator.document?.activePage.history.content.textAnnotations.isEmpty == true)
  }

  func testReplacementCancelsProductionFinalizeBeforeWorkerFinishes() throws {
    let fixture = makeFixture(pageCount: 1)
    let replacementFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      replacementFixture.view.dispose(); replacementFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    coordinator.pdfQueue.sync {}

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let finalize = try view.finalize()
    let finalizeCancelled = expectation(description: "finalize cancellation settles promptly")
    var finalizeError: Error?
    var finalizeRejectionCount = 0
    finalize.catch { error in
      finalizeError = error
      finalizeRejectionCount += 1
      finalizeCancelled.fulfill()
    }

    let replacement = Promise<PageInfo>()
    let replacementInstalled = expectation(description: "replacement installs after export worker release")
    replacement.then { _ in replacementInstalled.fulfill() }
    replacement.catch { error in XCTFail("replacement failed: \(error)") }
    let replacementURL = try XCTUnwrap(replacementFixture.view.documentCoordinator.document?.workingURL)
    view.beginLoad(replacementURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: replacement)

    XCTAssertNil(coordinator.document)
    wait(for: [finalizeCancelled], timeout: 2)
    XCTAssertTrue(finalizeError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertEqual(finalizeRejectionCount, 1)

    releaseWorker.signal()
    wait(for: [replacementInstalled], timeout: 5)
    coordinator.pdfQueue.sync {}
    XCTAssertEqual(finalizeRejectionCount, 1)
    XCTAssertNotNil(coordinator.document)
  }

  func testReplacementCancelsProductionPageMutationBeforeCandidatePublication() throws {
    let fixture = makeFixture(pageCount: 2)
    let replacementFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      replacementFixture.view.dispose(); replacementFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    coordinator.pdfQueue.sync {}

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let remove = try view.removePage()
    let removeCancelled = expectation(description: "page mutation cancellation settles promptly")
    var removeError: Error?
    var removeRejectionCount = 0
    remove.catch { error in
      removeError = error
      removeRejectionCount += 1
      removeCancelled.fulfill()
    }

    let replacement = Promise<PageInfo>()
    let replacementInstalled = expectation(description: "replacement installs after mutation worker release")
    replacement.then { _ in replacementInstalled.fulfill() }
    replacement.catch { error in XCTFail("replacement failed: \(error)") }
    let replacementURL = try XCTUnwrap(replacementFixture.view.documentCoordinator.document?.workingURL)
    view.beginLoad(replacementURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: replacement)

    XCTAssertNil(coordinator.document)
    wait(for: [removeCancelled], timeout: 2)
    XCTAssertTrue(removeError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertEqual(removeRejectionCount, 1)

    releaseWorker.signal()
    wait(for: [replacementInstalled], timeout: 5)
    coordinator.pdfQueue.sync {}
    XCTAssertEqual(removeRejectionCount, 1)
    XCTAssertEqual(coordinator.document?.pages.count, 1)
  }

  func testReplacementCancelsOnlyOperationsOwnedByThatMountedView() throws {
    let firstFixture = makeFixture(pageCount: 1)
    let secondFixture = makeFixture(pageCount: 1)
    defer {
      firstFixture.view.dispose(); firstFixture.window.isHidden = true
      secondFixture.view.dispose(); secondFixture.window.isHidden = true
    }
    let firstCoordinator = firstFixture.view.documentCoordinator
    firstCoordinator.pdfQueue.sync {}
    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    firstCoordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let firstExport = try firstFixture.view.finalize()
    let firstExportCancelled = expectation(description: "first view export is cancelled")
    var firstExportError: Error?
    firstExport.catch { error in
      firstExportError = error
      firstExportCancelled.fulfill()
    }
    let secondExport = try secondFixture.view.finalize()
    let secondExportCompleted = expectation(description: "second view export remains active")
    var secondOutput: String?
    secondExport.then { path in
      secondOutput = path
      secondExportCompleted.fulfill()
    }
    secondExport.catch { error in XCTFail("second view export failed: \(error)") }

    let replacement = Promise<PageInfo>()
    let replacementInstalled = expectation(description: "first view replacement installs")
    replacement.then { _ in replacementInstalled.fulfill() }
    replacement.catch { error in XCTFail("replacement failed: \(error)") }
    let replacementURL = try XCTUnwrap(secondFixture.view.documentCoordinator.document?.workingURL)
    firstFixture.view.beginLoad(replacementURL.path,
                                zoom: nil,
                                focus: nil,
                                fitToPage: true,
                                promise: replacement)

    wait(for: [firstExportCancelled], timeout: 2)
    XCTAssertTrue(firstExportError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    releaseWorker.signal()
    wait(for: [replacementInstalled, secondExportCompleted], timeout: 10)
    XCTAssertTrue(firstExportError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: try XCTUnwrap(secondOutput))).path))
  }

  func testPreparationFailureClearsExistingDocumentBeforeRejectingOnce() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let rejected = expectation(description: "preparation failure rejects after clear")
    let promise = Promise<PageInfo>()
    var rejectionCount = 0
    var documentWasClearedAtRejection = false
    promise.catch { _ in
      rejectionCount += 1
      documentWasClearedAtRejection = view.documentCoordinator.document == nil &&
        view.documentView.document == nil
      rejected.fulfill()
    }

    view.beginLoad("/missing/inksign-lifecycle-candidate.pdf",
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: promise)
    wait(for: [rejected], timeout: 5)

    XCTAssertEqual(rejectionCount, 1)
    XCTAssertTrue(documentWasClearedAtRejection)
    XCTAssertNil(view.pendingOpen)
    XCTAssertNil(view.attachedOverlayPage)
  }

  func testSupersededPresentationClearsAndStartsNewestPreparationWithoutBounds() throws {
    let fixture = makeFixture()
    let sourceFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      sourceFixture.view.dispose(); sourceFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let source = try XCTUnwrap(sourceFixture.view.documentCoordinator.document)
    let presentationBounds = view.documentView.bounds
    let candidateURL = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try Data(contentsOf: source.workingURL).write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = InkSignPdfDocumentState(sourceURL: source.sourceURL,
                                            workingURL: candidateURL,
                                            document: loaded.document,
                                            pages: loaded.pages)
    let operation = try XCTUnwrap(coordinator.admit(.open))
    let firstCancelled = expectation(description: "superseded presented open rejects after clear")
    let secondOpened = expectation(description: "newest open completes")
    var firstRejectionCount = 0
    let firstPromise = Promise<PageInfo>()
    firstPromise.catch { _ in
      firstRejectionCount += 1
      XCTAssertNil(coordinator.document)
      XCTAssertNil(view.documentView.document)
      XCTAssertNil(view.attachedOverlayPage)
      firstCancelled.fulfill()
    }
    let secondPromise = Promise<PageInfo>()
    secondPromise.then { _ in secondOpened.fulfill() }
    secondPromise.catch { error in XCTFail("newest open failed: \(error)") }
    XCTAssertTrue(coordinator.publish(candidate, operation: operation))
    view.overlayProvider.install(document: candidate.document, generation: operation.generation)
    view.documentView.document = candidate.document
    view.documentView.go(to: candidate.activePage.page)
    view.documentView.bounds = .zero
    view.pendingOpen = InkSignView.PendingOpen(operation: operation,
                                                promise: firstPromise,
                                                zoom: nil,
                                                focus: nil,
                                                fitToPage: true,
                                                phase: .awaitingReadiness)

    view.beginLoad(source.sourceURL.path,
                   zoom: nil,
                   focus: nil,
                   fitToPage: true,
                   promise: secondPromise)

    XCTAssertNotEqual(view.pendingOpen?.phase, .awaitingReadiness)
    XCTAssertEqual(view.pendingOpen?.phase, .preparing)
    XCTAssertNil(coordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertEqual(view.documentView.bounds, .zero)
    view.documentView.bounds = presentationBounds
    view.documentView.setNeedsLayout()
    view.documentView.layoutIfNeeded()
    wait(for: [firstCancelled, secondOpened], timeout: 20)

    XCTAssertEqual(firstRejectionCount, 1)
    XCTAssertNotNil(coordinator.document)
    XCTAssertTrue(coordinator.document !== original)
    XCTAssertEqual(coordinator.document?.sourceURL.standardizedFileURL,
                   source.sourceURL.standardizedFileURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
  }

  func testOverlayCallbackDuringDocumentAssignmentWaitsForPresentationPhase() throws {
    let fixture = makeFixture()
    let sourceFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      sourceFixture.view.dispose(); sourceFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let source = try XCTUnwrap(sourceFixture.view.documentCoordinator.document)
    let candidateURL = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try Data(contentsOf: source.workingURL).write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = InkSignPdfDocumentState(sourceURL: source.sourceURL,
                                            workingURL: candidateURL,
                                            document: loaded.document,
                                            pages: loaded.pages)
    let operation = try XCTUnwrap(coordinator.admit(.open))
    let promise = Promise<PageInfo>()
    var settlements = 0
    promise.then { _ in settlements += 1 }
    promise.catch { error in XCTFail("open failed: \(error)") }
    view.pendingOpen = InkSignView.PendingOpen(operation: operation,
                                                promise: promise,
                                                zoom: nil,
                                                focus: nil,
                                                fitToPage: true)

    XCTAssertTrue(coordinator.publish(candidate, operation: operation))
    view.overlayProvider.install(document: candidate.document, generation: operation.generation)
    view.documentView.document = candidate.document
    view.documentView.go(to: candidate.activePage.page)
    view.documentView.layoutIfNeeded()
    let canvas = try XCTUnwrap(view.overlayProvider.canvasView(for: candidate.activePage.id))
    view.overlayDidDisplay(canvas, for: candidate.activePage.id)
    XCTAssertEqual(settlements, 0)
    XCTAssertEqual(view.pendingOpen?.phase, .preparing)

    view.configureDoubleTapGestureRecognition()
    view.pendingOpen?.phase = .awaitingReadiness
    view.overlayDidDisplay(canvas, for: candidate.activePage.id)

    XCTAssertEqual(settlements, 1)
    XCTAssertNil(view.pendingOpen)
    XCTAssertTrue(view.documentCoordinator.document === candidate)
    XCTAssertTrue(view.documentView.currentPage === candidate.activePage.page)
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
  }

  func testFailedReplacementClearsDocumentAndEditingMode() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let target = ViewportTarget(zoom: 3, focus: CGPoint(x: 140, y: 180))
    XCTAssertTrue(view.applyViewport(target: target))
    view.setInteractionMode(editing: true)
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let rejected = expectation(description: "invalid replacement is rejected")
    var rejection: Error?
    let promise = Promise<PageInfo>()
    promise.catch { error in
      rejection = error
      rejected.fulfill()
    }

    view.beginLoad("", zoom: nil, focus: nil, fitToPage: true,
                   promise: promise)
    XCTAssertNil(view.documentCoordinator.document, "replacement clears the old document on admission")
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.overlayProvider.canvasView(for: original.activePage.id))
    XCTAssertFalse(view.editMode)
    wait(for: [rejected], timeout: 5)

    XCTAssertNotNil(rejection)
    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.attachedOverlayPage)
    XCTAssertFalse(view.editMode)
    view.documentCoordinator.pdfQueue.sync {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.workingURL.path))
  }

  func testUnreadableReplacementClearsViewModePresentation() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("invalid-\(UUID().uuidString).pdf")
    try Data("not a PDF".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let rejected = expectation(description: "unreadable replacement is rejected")
    let promise = Promise<PageInfo>()
    promise.catch { _ in rejected.fulfill() }
    view.beginLoad(source.path, zoom: nil, focus: nil, fitToPage: true, promise: promise)
    XCTAssertNil(view.documentCoordinator.document, "replacement clears the old document on admission")
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.overlayProvider.canvasView(for: original.activePage.id))
    XCTAssertFalse(view.editMode)
    wait(for: [rejected], timeout: 5)

    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.attachedOverlayPage)
    XCTAssertFalse(view.editMode)
    view.documentCoordinator.pdfQueue.sync {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.workingURL.path))
    XCTAssertNil(view.overlayProvider.canvasView(for: original.activePage.id))
  }

  func testPublishedReplacementFailureClearsPublishedAndPreviousDocuments() throws {
    let fixture = makeFixture()
    let sourceFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      sourceFixture.view.dispose(); sourceFixture.window.isHidden = true
    }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    view.documentView.bounds = .zero
    let source = try XCTUnwrap(sourceFixture.view.documentCoordinator.document)
    let candidateURL = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try Data(contentsOf: source.workingURL).write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = InkSignPdfDocumentState(sourceURL: source.sourceURL,
                                            workingURL: candidateURL,
                                            document: loaded.document,
                                            pages: loaded.pages)
    let operation = try XCTUnwrap(coordinator.admit(.open))
    let rejected = expectation(description: "failed presentation rejects after clearing")
    var rejection: Error?
    let promise = Promise<PageInfo>()
    promise.catch { error in
      rejection = error
      rejected.fulfill()
    }
    view.pendingOpen = InkSignView.PendingOpen(operation: operation,
                                                promise: promise,
                                                zoom: nil,
                                                focus: nil,
                                                fitToPage: true,
                                                phase: .awaitingReadiness)
    XCTAssertTrue(coordinator.publish(candidate, operation: operation))
    view.overlayProvider.install(document: candidate.document, generation: operation.generation)
    view.documentView.document = candidate.document
    view.documentView.go(to: candidate.activePage.page)
    XCTAssertEqual(view.pendingOpen?.phase, .awaitingReadiness)

    view.failOpenAttempt(error: InkSignView.LoadError.pdfLoadFailed)
    wait(for: [rejected], timeout: 5)

    XCTAssertNotNil(rejection)
    XCTAssertNil(view.pendingOpen)
    XCTAssertNil(coordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.attachedOverlayPage)
    coordinator.pdfQueue.sync {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.workingURL.path))
  }

  func testDisposeDuringOpenPreparationRejectsOnceAndIgnoresLateLoad() throws {
    let fixture = makeFixture()
    let promise = Promise<PageInfo>()
    let reentrantPromise = Promise<PageInfo>()
    var rejectionCount = 0
    var reentrantRejectionCount = 0
    let rejected = expectation(description: "disposed preparation rejects")
    let reentrantRejected = expectation(description: "open from rejection callback is cancelled")
    reentrantPromise.catch { error in
      guard case InkSignView.LoadError.cancelled = error else {
        XCTFail("open from a disposal callback was not cancelled: \(error)")
        reentrantRejected.fulfill()
        return
      }
      reentrantRejectionCount += 1
      reentrantRejected.fulfill()
    }
    promise.catch { _ in
      rejectionCount += 1
      rejected.fulfill()
      fixture.view.beginLoad("/missing/reentrant-inksign-replacement.pdf",
                             zoom: nil,
                             focus: nil,
                             fitToPage: true,
                             promise: reentrantPromise)
    }

    fixture.view.beginLoad("/missing/inksign-replacement.pdf",
                           zoom: nil,
                           focus: nil,
                           fitToPage: true,
                           promise: promise)
    fixture.view.dispose()
    wait(for: [rejected, reentrantRejected], timeout: 5)
    drainMainQueue()

    XCTAssertEqual(rejectionCount, 1)
    XCTAssertEqual(reentrantRejectionCount, 1)
    XCTAssertNil(fixture.view.documentCoordinator.document)
    XCTAssertNil(fixture.view.documentView.document)
    fixture.window.isHidden = true
  }

  func testDisposeDuringOpenPresentationReleasesCanvasAndRejectsOnce() throws {
    let fixture = makeFixture()
    let sourceFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      sourceFixture.view.dispose(); sourceFixture.window.isHidden = true
    }
    let view = fixture.view
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let source = try XCTUnwrap(sourceFixture.view.documentCoordinator.document)
    view.documentView.bounds = .zero
    let candidateURL = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    try Data(contentsOf: source.workingURL).write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = InkSignPdfDocumentState(sourceURL: source.sourceURL,
                                            workingURL: candidateURL,
                                            document: loaded.document,
                                            pages: loaded.pages)
    let operation = try XCTUnwrap(view.documentCoordinator.admit(.open))
    let promise = Promise<PageInfo>()
    var rejectionCount = 0
    let rejected = expectation(description: "disposed presentation rejects")
    promise.catch { _ in
      rejectionCount += 1
      rejected.fulfill()
    }
    view.pendingOpen = InkSignView.PendingOpen(operation: operation,
                                                promise: promise,
                                                zoom: nil,
                                                focus: nil,
                                                fitToPage: true,
                                                phase: .awaitingReadiness)
    XCTAssertTrue(view.documentCoordinator.publish(candidate, operation: operation))
    view.overlayProvider.install(document: candidate.document, generation: operation.generation)
    view.documentView.document = candidate.document
    view.documentView.go(to: candidate.activePage.page)
    let candidateCanvas = try XCTUnwrap(view.overlayProvider.canvasView(for: candidate.activePage.id))
    let candidateOverlay = try XCTUnwrap(candidateCanvas.superview as? InkSignPdfPageOverlayView)
    XCTAssertEqual(view.pendingOpen?.phase, .awaitingReadiness)

    view.dispose()
    wait(for: [rejected], timeout: 5)
    drainMainQueue()

    XCTAssertEqual(rejectionCount, 1)
    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.overlayProvider.owner)
    XCTAssertNil(candidateCanvas.owner)
    XCTAssertNil(candidateOverlay.superview)
    view.documentCoordinator.pdfQueue.sync {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.workingURL.path))
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

  func testOpenCompletionResolvesOnceWithoutLayoutReentry() throws {
    let fixture = makeFixture(applyInitialViewport: false)
    defer { fixture.window.isHidden = true }

    var resolutionCount = 0
    var rejectionCount = 0
    var stateEventCount = 0
    let promise = Promise<PageInfo>()
    promise.then { _ in resolutionCount += 1 }
    promise.catch { _ in rejectionCount += 1 }
    fixture.view.onStateChange = { _ in stateEventCount += 1 }
    let initialStateEventCount = stateEventCount
    let operation = try XCTUnwrap(fixture.view.documentCoordinator.admit(.structural))
    fixture.view.pendingOpen = InkSignView.PendingOpen(
      operation: operation,
      promise: promise,
      zoom: 2,
      focus: CGPoint(x: 150, y: 200),
      fitToPage: false,
      phase: .installing)

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])

    XCTAssertEqual(resolutionCount, 0)
    XCTAssertEqual(rejectionCount, 0)
    fixture.view.emitChange(force: true)
    XCTAssertEqual(stateEventCount, initialStateEventCount)

    fixture.view.pendingOpen?.phase = .awaitingReadiness
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])

    XCTAssertEqual(fixture.view.documentView.scaleFactor, 2, accuracy: 0.0001)
    XCTAssertEqual(resolutionCount, 1)
    XCTAssertEqual(rejectionCount, 0)
    XCTAssertEqual(stateEventCount, initialStateEventCount + 1)
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

}

/// Supplies the recognizer's admitted location; UIKit owns tap-versus-pan recognition.
private final class CoordinateTap: UITapGestureRecognizer {
  private let tapLocation: CGPoint
  init(location: CGPoint) {
    tapLocation = location
    super.init(target: nil, action: nil)
  }
  override var state: UIGestureRecognizer.State {
    get { .ended }
    set {}
  }
  override func location(in view: UIView?) -> CGPoint { tapLocation }
}
