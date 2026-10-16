import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewLifecycleTests: XCTestCase, InkSignViewTestSupport {
  func testAnimatedViewportCentersRequestedPointBeforeCompletion() throws {
    let fixture = makeFixture(pageCount: 1)
    let view = fixture.view
    defer { view.dispose(); fixture.window.isHidden = true }
    let session = try view.setMode(mode: .view, options: nil)
    _ = try awaitDocumentOperation(session.setViewport(
      options: ViewportOptions(x: 170, y: 120, zoom: 3)))
    XCTAssertFalse(view.interaction.viewport.motion.isRunning)
    let viewport = try view.getViewport()
    XCTAssertEqual(viewport.zoom, 3, accuracy: 0.01)
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let focused = view.documentView.convert(
      CGPoint(x: 170, y: 120).applying(page.geometry.displayToPDFTransform), from: view.viewerDocument!.pdfPage(for: page.id)!)
    XCTAssertEqual(focused.x, view.documentView.bounds.midX, accuracy: 1)
    XCTAssertEqual(focused.y, view.documentView.bounds.midY, accuracy: 1)
  }

  func testModeReplacementCancelsPendingViewportMotion() throws {
    guard !UIAccessibility.isReduceMotionEnabled else {
      throw XCTSkip("Reduced motion applies the viewport immediately")
    }
    let fixture = makeFixture(pageCount: 1)
    let view = fixture.view
    defer { view.dispose(); fixture.window.isHidden = true }
    let session = try view.setMode(mode: .view, options: nil)
    let cancelled = expectation(description: "superseded viewport rejects")
    let motion = try session.setViewport(options: ViewportOptions(x: 170, y: 120, zoom: 3))
    motion.then { _ in XCTFail("superseded motion must not complete"); cancelled.fulfill() }
    motion.catch { error in
      XCTAssertTrue(error.localizedDescription.hasPrefix("operation_cancelled"))
      cancelled.fulfill()
    }
    _ = try view.setMode(mode: .ink, options: nil)
    wait(for: [cancelled], timeout: 3)
    XCTAssertTrue(view.interaction.isInk)
    XCTAssertFalse(view.interaction.viewport.motion.isRunning)
  }

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
    try expectZoom(1) { view.interaction.viewport.scheduleZoomReport() }
    let fit = try XCTUnwrap(view.interaction.viewport.usableFitScale())
    try expectZoom(2) {
      view.interaction.viewport.applyViewport(request: .focus(nil, zoom: Double(fit * 2)))
    }
    try expectZoom(0.75) {
      view.interaction.viewport.applyViewport(request: .focus(nil, zoom: Double(fit * 0.75)))
    }
    try expectZoom(1) { _ = try view.switchPage(to: 1); view.interaction.viewport.applyViewport(request: .fit) }
    try expectZoom(1) { _ = try view.switchPage(to: 0); view.interaction.viewport.applyViewport(request: .fit) }
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
    let info = try attachDocument(from: source, to: fixture.view)
    XCTAssertEqual(info.pageCount, 1)
    XCTAssertEqual(info.width, 595.28, accuracy: 0.01)
    XCTAssertEqual(info.height, 841.89, accuracy: 0.01)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    let state = try XCTUnwrap(fixture.view.viewerDocument)
    let exported = try XCTUnwrap(PDFDocument(url: state.workingURL))
    XCTAssertEqual(exported.pageCount, 1)
  }

  func testCoordinateTapUsesDisplayedPagePointsAndConsumesOnlyOnce() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let owner = try attachedDocument(view)
    try awaitDocumentOperation(owner.rotatePage(index: 0, degrees: 90))
    try awaitViewerPageReady(view)
    let session = try view.setMode(mode: .ink, options: nil)
    let request = try session.requestUserTap()
    var requestError: Error?
    request.catch { requestError = $0 }
    // A later command completing proves the tap wait released the FIFO queue.
    try awaitModeChange(view.enqueueViewerCommand { Promise<Void>.resolved() })
    XCTAssertNil(requestError, "Coordinate selection failed before the user tapped")
    XCTAssertTrue(view.isPickingPageCoords)
    XCTAssertTrue(view.interactionMode() == .pagecoords)
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let point = CGPoint(x: 60, y: 90)
    let location = view.documentView.convert(point.applying(page.geometry.displayToPDFTransform), from: view.viewerDocument!.pdfPage(for: page.id)!)
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
    XCTAssertTrue(view.interactionMode() == .ink)
    XCTAssertTrue(page.history.content.textAnnotations.isEmpty)
    XCTAssertTrue(page.history.content.drawing.strokes.isEmpty)
  }

  func testCoordinateRequestsCancelOnModeChangeCloseAndDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    var errors: [Error] = []
    try view.requestUserTap().catch { errors.append($0) }
    try view.setMode(mode: .view, options: nil)
    try view.setMode(mode: .view, options: nil)
    try view.requestUserTap().catch { errors.append($0) }
    try awaitDocumentOperation((view.document as! HybridInkSignDocument).close())
    XCTAssertEqual(errors.count, 2)
    XCTAssertFalse(view.isPickingPageCoords)
    XCTAssertNil(view.interaction.coordinateRequest)
    // Queue admission is deliberately held so disposal also covers a not-yet-armed request.
    let held = Promise<Void>()
    view.enqueueViewerCommand { held }
    try view.requestUserTap().catch { errors.append($0) }
    view.dispose()
    XCTAssertEqual(errors.count, 3)
    XCTAssertTrue(errors.allSatisfy { $0.localizedDescription.hasPrefix("operation_cancelled:") })
  }

  func testCoordinatePickerCancelsWhenItsCapturedPageChanges() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let firstPageID = try XCTUnwrap(view.viewerDocument?.activePage.id)
    let session = try view.setMode(mode: .ink, options: nil)
    var errors: [Error] = []
    var coordinates: [PageCoords] = []
    try session.requestUserTap().then { coordinates.append($0) }.catch { errors.append($0) }
    try awaitModeChange(view.enqueueViewerCommand { Promise<Void>.resolved() })
    XCTAssertTrue(view.interactionMode() == .pagecoords)
    try view.switchPage(to: 1)
    XCTAssertNotEqual(view.viewerDocument?.activePage.id, firstPageID)
    view.handleCoordinateTap(CoordinateTap(location: CGPoint(x: 100, y: 100)))
    XCTAssertTrue(coordinates.isEmpty)
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].localizedDescription.hasPrefix("operation_cancelled:"))
    XCTAssertNil(view.interaction.coordinateRequest)
    XCTAssertTrue(view.interactionMode() == .ink)
    let nextPage = try awaitDocumentOperation(session.getPage(pageIndex: .first(1)))
    XCTAssertNoThrow(try nextPage.getInputTargets())
  }

  func testPDFViewOwnsPresentationAndRequestsPageSpecificOverlays() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.window.isHidden = true }

    let state = try XCTUnwrap(fixture.view.viewerDocument)
    let first = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: state.document.page(at: 0)!))
    let second = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: state.document.page(at: 1)!))

    XCTAssertEqual(fixture.view.documentView.displayMode, .singlePage)
    XCTAssertTrue(fixture.view.documentView.pageOverlayViewProvider ===
                  fixture.view.overlayProvider)
    XCTAssertTrue(fixture.view.documentView.currentPage === state.activePDFPage)
    XCTAssertEqual(fixture.view.documentView.backgroundColor, UIColor.white)
    XCTAssertFalse(first === second)
    XCTAssertTrue(fixture.view.overlayProvider.canvasView === fixture.view.canvasView)
  }

  func testEndedPageOverlayCanBeRecreatedFromCoordinatorState() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let state = try XCTUnwrap(fixture.view.viewerDocument)
    let page = state.activePDFPage
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
    XCTAssertEqual(fixture.view.viewerDocument?.activePage.id, pageID)
    XCTAssertTrue(state.activePage.history.content.equals(committedContent))
    XCTAssertEqual(newCanvas.drawing.strokes.count, 1)
  }

  func testDocumentUsesStablePageIdentityAndRetainsWorkingArtifactForReaders() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let workingURL = try XCTUnwrap(fixture.view.viewerDocument).workingURL
    let owner = try XCTUnwrap(fixture.view.document as? HybridInkSignDocument)
    let coordinator = owner.core.coordinator
    do {
    let document = try XCTUnwrap(fixture.view.viewerDocument)
    let activeID = document.activePageID
    let pageIDs = document.pages.map(\.id)

    XCTAssertEqual(document.activePage.id, activeID)
    XCTAssertEqual(document.index(of: activeID), 1)
    XCTAssertTrue(fixture.view.viewerDocument!.selectPage(at: 2))
    XCTAssertEqual(document.activePage.id, document.pages[2].id)
    XCTAssertTrue(fixture.view.viewerDocument!.selectPage(at: 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))

    try awaitDocumentOperation(owner.close())
    coordinator.pdfQueue.sync {}

    XCTAssertTrue(FileManager.default.fileExists(atPath: workingURL.path))
    XCTAssertEqual(document.pages.map(\.id), pageIDs)
    }
    coordinator.pdfQueue.sync {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: workingURL.path))
  }

  func testPageHandleOutlivesDocumentWrapperUntilOwnerClose() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    var owner: HybridInkSignDocument? = try attachedDocument(fixture.view)
    weak var weakOwner = owner
    let core = try XCTUnwrap(owner?.core)
    let page = try documentPage(fixture.view)

    fixture.view.document = nil
    owner = nil
    XCTAssertNil(weakOwner)

    let bounds = TextAnnotationBounds(x: 40, y: 50, width: 140, height: 50)
    let targetID = try page.createInputArea(options: CreateInputAreaOptions(bounds: bounds,
      font: nil, fontSize: 16, color: nil, direction: .ltr, maxLines: 1,
      alignment: .start, verticalAnchor: .top))
    try page.setTextValue(id: targetID, text: "retained page", options: nil)
    XCTAssertEqual(try page.getTextValue(id: targetID), "retained page")

    try awaitTestPromise(core.close())
    XCTAssertThrowsError(try page.getTextValue(id: targetID))
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

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      releaseWorker.wait()
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 10), .success)

    let open = try XCTUnwrap(coordinator.admit(.open))
    XCTAssertNil(coordinator.document, "open admission clears the previous document")
    XCTAssertFalse(coordinator.isCurrent(finalize), "replacement invalidates finalize")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.source.path),
                  "replacement leaves worker-owned export input until worker cleanup")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.output.path),
                  "replacement leaves worker-owned output until worker cleanup")
    XCTAssertNil(coordinator.admit(.finalize), "replacement open owns the coordinator")
    coordinator.settle(open)
    XCTAssertNil(coordinator.document, "failed replacement leaves the view empty")

    releaseWorker.signal()
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
    let state = try XCTUnwrap(fixture.view.viewerDocument)
    let ids = state.pages.map(\.id)
    let appended = try XCTUnwrap(appendedFixture.view.viewerDocument?.pages.first)

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
    let owner = try attachedDocument(view)

    XCTAssertThrowsError(try awaitDocumentOperation(owner.removePage(index: 0)))
    XCTAssertThrowsError(try awaitDocumentOperation(owner.movePage(fromIndex: 0, toIndex: 2)))
    try awaitDocumentOperation(owner.movePage(fromIndex: 0, toIndex: 0))

    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(view.viewerDocument?.activePage.history.content.isEmpty == true)
    XCTAssertEqual(view.documentCoordinator.generation, generation)
  }

  func testAddPagesWithEmptySourceListReturnsWithoutPublishingAMutation() throws {
    let fixture = makeFixture(pageCount: 2, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let generation = coordinator.generation
    let owner = try attachedDocument(view)
    let result = try awaitTestPromise(owner.addPages(options: DocumentAddPagesOptions(
      type: nil, tag: nil, sources: [], imagePageSize: nil, targetDpi: nil, jpegQuality: nil)))

    XCTAssertEqual(result.addedPageCount, 0)
    XCTAssertEqual(result.pageCount, 2)
    XCTAssertTrue(coordinator.document === original)
    XCTAssertEqual(coordinator.generation, generation)
    XCTAssertEqual(view.viewerDocument?.activePageIndex, 1)
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

    let view = fixture.view
    let owner = try attachedDocument(view)
    let activePageID = try XCTUnwrap(view.viewerDocument?.activePageID)
    let result = try awaitTestPromise(owner.addPages(options: DocumentAddPagesOptions(type: nil, tag: nil,
      sources: [pdfURL.path, imageURL.path],
      imagePageSize: ImagePageSize(width: 144, height: 72),
      targetDpi: 72, jpegQuality: 0.1)))

    XCTAssertEqual(result.addedPageCount, 2)
    XCTAssertEqual(result.pageCount, 3)
    try awaitViewerPageReady(view, pageID: activePageID)
    let pages = try XCTUnwrap(view.documentCoordinator.document?.pages)
    XCTAssertEqual(pages.count, 3)
    XCTAssertEqual(pages[1].geometry.mediaBox.width, 90, accuracy: 0.01)
    XCTAssertEqual(pages[1].geometry.mediaBox.height, 45, accuracy: 0.01)
    XCTAssertEqual(pages[2].geometry.mediaBox.width, 144, accuracy: 0.01)
    XCTAssertEqual(pages[2].geometry.mediaBox.height, 72, accuracy: 0.01)
  }

  func testAddPagesPreservesActivePageIdentity() throws {
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

    let view = fixture.view
    let owner = try attachedDocument(view)
    let originalActiveID = try XCTUnwrap(view.viewerDocument?.activePageID)
    let result = try awaitTestPromise(owner.addPages(options: DocumentAddPagesOptions(
      type: nil, tag: nil, sources: [sourceURL.path], imagePageSize: nil,
      targetDpi: nil, jpegQuality: nil)))

    try awaitViewerPageReady(view, pageID: originalActiveID)
    let document = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(result.addedPageCount, 2)
    XCTAssertEqual(result.pageCount, 5)
    XCTAssertEqual(document.activePageID, originalActiveID)
    XCTAssertEqual(document.activePageIndex, 1)
  }

  func testMoveAndRemoveCommandsPublishFinalPageOrder() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let original = try XCTUnwrap(view.viewerDocument)
    let movedID = original.activePageID
    let annotation = makeCenteredTextAnnotation(
      id: 12, text: "kept", fontSize: 18,
      pageSize: original.activePage.geometry.mediaBox.size)
    XCTAssertTrue(original.activePage.history.appendText(annotation))

    let owner = try attachedDocument(view)
    try awaitDocumentOperation(owner.movePage(fromIndex: 1, toIndex: 0))
    try awaitViewerPageReady(view, pageID: movedID)

    let afterMove = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(afterMove.pages.map(\.geometry.mediaBox.width), [400, 300, 500])
    XCTAssertEqual(afterMove.activePageID, movedID)
    XCTAssertEqual(afterMove.activePage.history.content.textAnnotations.first?.text, "kept")

    let nextPageID = afterMove.pages[1].id
    try awaitDocumentOperation(owner.removePage(index: 0))
    try awaitViewerPageReady(view, pageID: nextPageID)

    let afterRemove = try XCTUnwrap(view.viewerDocument)
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
    let output = try owner.finalize()
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
    let document = try XCTUnwrap(view.viewerDocument)
    let owner = try attachedDocument(view)
    let page = document.activePage
    let pageID = page.id
    let pageHandle = try documentPage(view, at: 0)

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

    let workingURLBefore = try XCTUnwrap(view.viewerDocument?.workingURL)
    let workingBytesBefore = try Data(contentsOf: workingURLBefore)
    try view.setMode(mode: .ink, options: nil)
    try awaitDocumentOperation(owner.rotatePage(index: 0, degrees: 90))
    try awaitViewerPageReady(view, pageID: pageID)
    let afterRotation = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(view.attachedOverlayPage, pageID)
    XCTAssertTrue(view.overlayProvider.isDisplaying(afterRotation.activePDFPage))
    XCTAssertTrue(view.canvasView === view.overlayProvider.canvasView(for: pageID))
    XCTAssertTrue(view.documentView.isUserInteractionEnabled)
    XCTAssertTrue(view.canvasView.drawingGestureRecognizer.isEnabled)
    XCTAssertTrue(view.interaction.isInk)
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
    _ = try awaitDocumentOperation(owner.addPages(options: DocumentAddPagesOptions(type: nil, tag: nil,
      sources: [workingURLBefore.path], imagePageSize: nil, targetDpi: nil, jpegQuality: nil)))
    try awaitViewerPageReady(view, pageID: pageID)
    XCTAssertEqual(view.viewerDocument?.activePageID, pageID)
    XCTAssertEqual(view.viewerDocument?.activePage.geometry.rotation, 90)
    _ = try awaitDocumentOperation(owner.movePage(fromIndex: 0, toIndex: 1))
    try awaitViewerPageReady(view, pageID: pageID)
    let afterMove = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(afterMove.pages[1].id, pageID)
    XCTAssertTrue(afterMove.pages[1].history === page.history)
    XCTAssertTrue(afterMove.pages[1].history.content.equals(contentBefore))
    XCTAssertTrue(afterMove.pages[1].history.state.canRedo)
    // Remove the appended page while retaining the rotated page by identity.
    _ = try awaitDocumentOperation(owner.removePage(index: 0))
    try awaitViewerPageReady(view, pageID: pageID)
    let afterAssembly = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(afterAssembly.pages.map(\.id), [pageID])
    XCTAssertEqual(afterAssembly.activePage.geometry.rotation, 90)
    XCTAssertEqual(afterAssembly.activePage.sourceGeometry.rotation, 0)
    XCTAssertTrue(afterAssembly.activePage.history === page.history)
    XCTAssertTrue(afterAssembly.activePage.history.content.equals(contentBefore))
    XCTAssertTrue(afterAssembly.activePage.history.state.canRedo)

    try pageHandle.redo()
    view.defaultTextColor = "#D00000"
    drainMainQueue()
    try insertTextForTest("New text",
      bounds: TextAnnotationBounds(x: 60, y: 160, width: 160, height: 24),
      options: nil, in: view)

    let exported = expectation(description: "export rotated PDF")
    var outputURL: URL?
    var exportError: Error?
    let output = try owner.finalize()
    output.then { path in outputURL = URL(string: path)!; exported.fulfill() }
    output.catch { error in exportError = error; exported.fulfill() }
    wait(for: [exported], timeout: 30)
    XCTAssertNil(exportError)
    let reopenedURL = try XCTUnwrap(outputURL)
    let reopened = try XCTUnwrap(PDFDocument(url: reopenedURL))
    XCTAssertEqual(reopened.pageCount, 1)
    XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
    XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("Approved"))
    XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("New text"))
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
    XCTAssertFalse(try XCTUnwrap(view.viewerDocument).activePage.history.content.drawing.strokes.isEmpty)
    for _ in 0..<3 {
      let completed = expectation(description: "compose quarter turn")
      let next = try owner.rotatePage(index: 0, degrees: 90)
      next.then { _ in completed.fulfill() }
      next.catch { error in XCTFail("composed rotation failed: \(error)"); completed.fulfill() }
      wait(for: [completed], timeout: 30)
      try awaitViewerPageReady(view, pageID: pageID)
    }
    let restored = try XCTUnwrap(view.viewerDocument)
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
    _ = try attachDocument(from: url, to: view)
    let owner = try attachedDocument(view)
    for angle in [0, 90, 180, 270] {
      if angle != 0 {
        try awaitDocumentOperation(owner.rotatePage(index: 0, degrees: 90))
        try awaitViewerPageReady(view)
      }
      let state = try XCTUnwrap(view.viewerDocument)
      let historyBefore = state.activePage.history.content
      let modeBefore = view.interaction.isInk
      let page = try documentPage(view)
      let textOptions = ResolveInputUnderlineOptions(fieldName: "Name", bounds: nil, occurrence: nil,
        font: nil, fontSize: nil, color: "#D00000", direction: .ltr, maxLines: 2,
        alignment: nil, verticalAnchor: .bottom)
      if angle == 90 || angle == 270 {
        do {
          _ = try resolveInputTarget(page, options: textOptions)
          XCTFail("A vertical rule must not accept field insertion")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("text_rule_not_found")) }
        XCTAssertTrue(state.activePage.history.content.equals(historyBefore))
        XCTAssertEqual(view.interaction.isInk, modeBefore)
        continue
      }
      let textID = try resolveInputTarget(page, options: textOptions)
      try page.setTextValue(id: textID, text: "OK", options: nil)
      let annotation = try XCTUnwrap(state.activePage.history.content.textAnnotations.last)
      let ruleY: CGFloat = angle == 0 ? 132 : 268
      let field = CGRect(x: angle == 0 ? 210 : 190, y: 0,
                         width: angle == 0 ? 70 : 90, height: ruleY)
      XCTAssertEqual(annotation.flowBounds, field)
      XCTAssertEqual(annotation.layoutRotation, angle)
      XCTAssertLessThanOrEqual(annotation.bounds.maxY, ruleY)
      for anchor in [FieldFocusVerticalAnchor.top, .bottom] {
        _ = try awaitDocumentOperation(view.focusInputTarget(page: page, id: textID,
          options: InputTargetFocusOptions(zoom: 5,
                                     verticalAnchor: anchor, edgeOffset: 8)))
        view.documentView.layoutIfNeeded()
        let viewport = view.documentView.bounds
        let pdfCenter = view.documentView.convert(CGPoint(x: viewport.midX, y: viewport.midY),
                                                   to: state.activePDFPage)
        var displayedCenter = pdfCenter.applying(
          state.activePage.geometry.displayToPDFTransform.inverted())
        let pdfTopLeft = view.documentView.convert(
          CGPoint(x: viewport.minX, y: viewport.minY), to: state.activePDFPage)
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
            to: state.activePDFPage)
          displayedCenter = settledPDFCenter.applying(
            state.activePage.geometry.displayToPDFTransform.inverted())
          let settledPDFTopLeft = view.documentView.convert(
            CGPoint(x: settledViewport.minX, y: settledViewport.minY),
            to: state.activePDFPage)
          displayedTopLeft = settledPDFTopLeft.applying(
            state.activePage.geometry.displayToPDFTransform.inverted())
        }
        XCTAssertEqual(displayedCenter.y, clampedY, accuracy: 2,
          "rotation=\(angle), anchor=\(anchor), zoom=\(view.documentView.scaleFactor), " +
          "requestedCenter=\(clampedY), visibleTopLeft=\(displayedTopLeft), halfHeight=\(halfHeight), " +
          "destination=\(String(describing: view.documentView.currentDestination?.point))")
      }
      let output = try awaitDocumentOperation(owner.finalize())
      let outputURL = try XCTUnwrap(URL(string: output))
      defer { try? FileManager.default.removeItem(at: outputURL) }
      let exported = try XCTUnwrap(PDFDocument(url: outputURL))
      let pixels = try rotationPixelBounds(in: XCTUnwrap(exported.page(at: 0))) { red, green, blue in
        Int(red) > Int(green) + 60 && Int(red) > Int(blue) + 60
      }
      // Only this insertion remains red in the following iteration.
      XCTAssertTrue(field.insetBy(dx: -2, dy: -2).contains(pixels))
      XCTAssertGreaterThan(pixels.width, pixels.height)
      try page.clear()
    }
  }

  private func awaitDocumentOperation<T>(_ promise: Promise<T>) throws -> T {
    let completed = expectation(description: "document operation settles")
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
    let fixtureCandidate = try XCTUnwrap(candidateFixture.view.viewerDocument)
    let candidateData = try Data(contentsOf: fixtureCandidate.workingURL)
    let candidateURL = try coordinator.artifactPolicy.allocateWorkingSource()
    try candidateData.write(to: candidateURL, options: .atomic)
    let loadedCandidate = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidatePages = try fixtureCandidate.pages.enumerated().map { index, old in
      InkSignPdfDocumentCandidateLoader.rebinding(old, to: loadedCandidate.pages[index])
    }
    let candidate = CommittedDocumentState(sourceURL: fixtureCandidate.sourceURL,
                                            workingURL: candidateURL,
                                            pages: candidatePages)
    defer {
      if coordinator.document !== candidate {
        coordinator.artifactPolicy.deleteExact(candidateURL)
      }
    }
    let operation = try XCTUnwrap(coordinator.admit(.structural))

    XCTAssertTrue(coordinator.publishStructural(candidate, operation: operation) === original)
    XCTAssertTrue(coordinator.document === candidate)
    XCTAssertTrue(coordinator.structuralDirty)
    coordinator.settle(operation)

    let staleCandidate = try XCTUnwrap(candidateFixture.view.documentCoordinator.document)
    let staleOperation = try XCTUnwrap(coordinator.admit(.structural))
    _ = coordinator.nextGeneration()
    XCTAssertNil(coordinator.publishStructural(staleCandidate, operation: staleOperation))
    XCTAssertTrue(coordinator.document === candidate)
    coordinator.settle(staleOperation)
  }

  func testCoordinatorCanPublishTheFirstAddedDocument() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let source = try XCTUnwrap(fixture.view.viewerDocument)
    let data = try Data(contentsOf: source.workingURL)
    let artifacts = InkSignPdfCacheArtifactPolicy.shared
    let candidateURL = try artifacts.allocateWorkingSource()
    defer { artifacts.deleteExact(candidateURL) }
    try data.write(to: candidateURL, options: .atomic)
    let loaded = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidate = CommittedDocumentState(sourceURL: candidateURL,
                                            workingURL: candidateURL,

                                            pages: loaded.pages)
    let coordinator = InkSignPdfDocumentCoordinator(artifactPolicy: artifacts)
    defer { coordinator.dispose() }
    let operation = try XCTUnwrap(coordinator.admit(.structural))

    XCTAssertTrue(coordinator.publishInitialStructural(candidate, operation: operation))
    XCTAssertTrue(coordinator.document === candidate)
    XCTAssertEqual(coordinator.document?.pages.count, 1)
    XCTAssertTrue(coordinator.structuralDirty)
    coordinator.settle(operation)
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
    try attachDocument(from: keyPDFURL, to: view)
    let coordinator = view.documentCoordinator
    XCTAssertEqual(coordinator.document?.pages.count, 2)
    let keyPage = try XCTUnwrap(coordinator.document?.pages.first)
    let analysis = keyPage.sourceAnalysis
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

    let page = try documentPage(view, at: 0)
    XCTAssertEqual(try view.switchPage(to: 1).pageIndex, 1)
    XCTAssertEqual(view.viewerDocument?.activePageIndex, 1)
    let textID = try resolveInputTarget(page, options: ResolveInputUnderlineOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, font: nil, fontSize: nil, color: nil,
      direction: nil, maxLines: nil, alignment: nil, verticalAnchor: nil))
    try page.setTextValue(id: textID, text: "filled", options: nil)
    XCTAssertEqual(view.viewerDocument?.activePageIndex, 1)
    XCTAssertEqual(coordinator.document?.pages[0].history.content.textAnnotations.map(\.text), ["filled"])
    XCTAssertTrue(coordinator.document?.pages[1].history.content.textAnnotations.isEmpty == true)
  }

  func testPreparedPageUsesCurrentGeometryAfterRotation() throws {
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
    try attachDocument(from: keyPDFURL, to: view)
    let owner = try attachedDocument(view)
    let page = try documentPage(view)
    try awaitDocumentOperation(owner.rotatePage(index: 0, degrees: 90))
    try awaitViewerPageReady(view)
    let document = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(document.activePage.geometryRevision, 1)
    XCTAssertTrue(document.activePage.history.content.textAnnotations.isEmpty)
    XCTAssertThrowsError(try resolveInputTarget(page, options: ResolveInputUnderlineOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, font: nil, fontSize: nil, color: nil,
      direction: .ltr, maxLines: nil, alignment: nil, verticalAnchor: .bottom))) {
      XCTAssertTrue($0.localizedDescription.hasPrefix("text_rule_not_found"))
    }
  }

  func testPreparedPageFocusRejectsVerticalRuleAfterRotation() throws {
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
    try attachDocument(from: keyPDFURL, to: view)
    let owner = try attachedDocument(view)
    let page = try documentPage(view)
    let id = try resolveInputTarget(page, options: ResolveInputUnderlineOptions(
      fieldName: "Name", bounds: nil, occurrence: nil, font: nil, fontSize: nil,
      color: nil, direction: .ltr, maxLines: nil, alignment: nil, verticalAnchor: nil))
    try awaitDocumentOperation(owner.rotatePage(index: 0, degrees: 90))
    try awaitViewerPageReady(view)
    XCTAssertEqual(view.viewerDocument?.activePage.geometryRevision, 1)
    XCTAssertTrue(view.viewerDocument?.activePage.history.content.textAnnotations.isEmpty == true)
    XCTAssertThrowsError(try awaitDocumentOperation(view.focusInputTarget(page: page, id: id,
      options: InputTargetFocusOptions(zoom: 3, verticalAnchor: .bottom, edgeOffset: 8)))) {
      XCTAssertTrue($0.localizedDescription.hasPrefix("text_rule_not_found"))
    }
  }

  func testFieldFocusWaitsForStructuralPresentationAfterMutation() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let owner = try attachedDocument(view)
    let page = try documentPage(view)
    let targetID = try createInputTarget(page, options: CreateInputAreaOptions(
      bounds: TextAnnotationBounds(x: 40, y: 60, width: 120, height: 36),
      font: nil, fontSize: 16, color: nil, direction: .ltr, maxLines: 1,
      alignment: .start, verticalAnchor: .top))
    try page.setTextValue(id: targetID, text: "Focus", options: nil)

    try awaitTestPromise(owner.rotatePage(index: 0, degrees: 90))
    try holdCurrentStructuralPresentation(view)
    XCTAssertNotNil(view.interaction.presentation,
                    "Focus should encounter the current structural presentation request")

    var focusResult: Result<Void, Error>?
    let focus = try view.focusInputTarget(page: page, id: targetID,
      options: InputTargetFocusOptions(zoom: 3, verticalAnchor: .center, edgeOffset: 0))
    focus.then { focusResult = .success(()) }
    focus.catch { focusResult = .failure($0) }
    XCTAssertNil(focusResult, "Focus must wait for the pending structural presentation")
    XCTAssertFalse(view.interaction.viewport.motion.isRunning)

    try completeCurrentPagePresentation(view)
    try awaitDocumentOperation(focus)
    XCTAssertEqual(view.viewerDocument?.activePage.geometryRevision, 1)
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.02)
    XCTAssertNil(view.interaction.presentation)
  }

  func testFieldFocusWaitingForPresentationCancelsOnDocumentReplacement() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let inactivePage = try documentPage(view, at: 1)
    let oldPageID = try XCTUnwrap(UUID(uuidString: inactivePage.getState().pageId))
    let targetID = try createInputTarget(inactivePage, options: CreateInputAreaOptions(
      bounds: TextAnnotationBounds(x: 40, y: 60, width: 120, height: 36),
      font: nil, fontSize: 16, color: nil, direction: .ltr, maxLines: 1,
      alignment: .start, verticalAnchor: .top))
    try inactivePage.setTextValue(id: targetID, text: "Do not navigate", options: nil)

    try holdCurrentStructuralPresentation(view)
    XCTAssertNotNil(view.interaction.presentation)

    var focusSucceeded = false
    var focusError: Error?
    let focusSettled = expectation(description: "pending focus is cancelled by document replacement")
    let focus = try view.focusInputTarget(page: inactivePage, id: targetID,
      options: InputTargetFocusOptions(zoom: 4, verticalAnchor: .center, edgeOffset: 0))
    focus.then { focusSucceeded = true; focusSettled.fulfill() }
    focus.catch { focusError = $0; focusSettled.fulfill() }
    XCTAssertFalse(focusSucceeded)

    let replacementCore = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    let source = try XCTUnwrap(view.viewerDocument?.workingURL)
    try awaitTestPromise(initializeDocument(replacementCore, from: source))
    let replacement = HybridInkSignDocument(core: replacementCore)
    let replacementPageID = try XCTUnwrap(replacementCore.coordinator.document?.pages.first?.id)
    view.document = replacement
    wait(for: [focusSettled], timeout: 5)
    XCTAssertFalse(focusSucceeded)
    XCTAssertTrue(focusError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertNotEqual(replacementPageID, oldPageID)
    XCTAssertEqual(view.viewerDocument?.activePage.id, replacementPageID)

    try completeCurrentPagePresentation(view)
    try awaitViewerPageReady(view, pageID: replacementPageID)
    let replacementZoom = try view.getViewport().zoom
    drainMainQueue()
    XCTAssertEqual(view.viewerDocument?.activePage.id, replacementPageID)
    XCTAssertEqual(try view.getViewport().zoom, replacementZoom, accuracy: 0.001,
                   "Cancelled focus must not animate after replacement presentation completes")
    XCTAssertFalse(view.interaction.viewport.motion.isRunning)
  }

  func testFieldFocusSucceedsImmediatelyAfterRotationMutation() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let owner = try attachedDocument(view)
    let page = try documentPage(view)
    let targetID = try createInputTarget(page, options: CreateInputAreaOptions(
      bounds: TextAnnotationBounds(x: 40, y: 60, width: 120, height: 36),
      font: nil, fontSize: 16, color: nil, direction: .ltr, maxLines: 1,
      alignment: .start, verticalAnchor: .top))
    try page.setTextValue(id: targetID, text: "Focus", options: nil)

    try awaitTestPromise(owner.rotatePage(index: 0, degrees: 90))
    let focus = try view.focusInputTarget(page: page, id: targetID,
      options: InputTargetFocusOptions(zoom: 3, verticalAnchor: .center, edgeOffset: 0))
    try awaitDocumentOperation(focus)

    XCTAssertEqual(view.viewerDocument?.activePage.geometryRevision, 1)
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.02)
  }

  func testModeSessionCancelsQueuedFocusAndRetainsCommittedText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let ordinaryPage = try documentPage(view)
    let session = try view.setMode(mode: .ink, options: nil)
    let page = try awaitDocumentOperation(session.getPage(pageIndex: nil))
    let textID = try createInputTarget(page, options: CreateInputAreaOptions(
      bounds: TextAnnotationBounds(x: 50, y: 60, width: 100, height: 30),
      font: nil, fontSize: nil, color: nil, direction: nil, maxLines: nil,
      alignment: nil, verticalAnchor: nil))
    var modes: [String] = []
    view.onStateChange = { modes.append($0.mode.stringValue) }
    try page.setTextValue(id: textID, text: "Ada", options: nil)
    let beforeFocus = try view.interaction.viewport.currentViewportSnapshot().zoom
    let gate = Promise<Void>()
    let blocked = view.enqueueViewerCommand { gate }
    let focus = try session.focusInputTarget(page: page, id: textID,
      options: InputTargetFocusOptions(zoom: 3,
        verticalAnchor: nil, edgeOffset: nil))
    let cancelled = expectation(description: "queued session focus cancels promptly")
    focus.catch { error in
      XCTAssertTrue(error.localizedDescription.hasPrefix("operation_cancelled"))
      cancelled.fulfill()
    }
    try view.setMode(mode: .text, options: nil)
    XCTAssertFalse(view.interaction.isInk)
    XCTAssertTrue(view.textInteractionOverlay.hasPendingPlacement())
    wait(for: [cancelled], timeout: 2)
    XCTAssertThrowsError(try page.setTextValue(id: textID, text: "Stale", options: nil))
    XCTAssertEqual(try ordinaryPage.getTextValue(id: textID), "Ada")

    gate.resolve()
    try awaitModeChange(blocked)
    try awaitModeChange(view.enqueueViewerCommand { Promise<Void>.resolved() })
    XCTAssertTrue(view.textInteractionOverlay.hasPendingPlacement())
    XCTAssertFalse(view.interaction.isInk)
    XCTAssertEqual(try view.interaction.viewport.currentViewportSnapshot().zoom, beforeFocus, accuracy: 0.01)
    try view.setMode(mode: .view, options: nil)
    XCTAssertFalse(view.textInteractionOverlay.hasPendingPlacement())
    XCTAssertEqual(modes.last, "view")
  }

  func testModeSessionCancelsQueuedPageAcquisition() throws {
    let fixture = makeFixture(pageCount: 1)
    let view = fixture.view
    defer { view.dispose(); fixture.window.isHidden = true }
    let gate = Promise<Void>()
    let blocked = view.enqueueViewerCommand { gate }
    let session = try view.setMode(mode: .ink, options: nil)
    let preparing = try session.getPage(pageIndex: nil)
    let cancelled = expectation(description: "mode replacement cancels queued page acquisition")
    var rejectionCount = 0
    preparing.then { _ in XCTFail("Cancelled acquisition returned a page") }
    preparing.catch { error in
      XCTAssertTrue(error.localizedDescription.hasPrefix("operation_cancelled"))
      rejectionCount += 1
      cancelled.fulfill()
    }
    try view.setMode(mode: .ink, options: nil) // The same mode still starts a new session.
    wait(for: [cancelled], timeout: 2)
    let owner = try attachedDocument(view)
    let independent = try owner.getPage(index: .first(0))
    gate.resolve()
    try awaitModeChange(blocked)
    let page = try awaitDocumentOperation(independent)
    XCTAssertEqual(rejectionCount, 1)
    XCTAssertNoThrow(try page.getInputTargets())
    XCTAssertThrowsError(try session.getPage(pageIndex: nil))
  }

  func testStructuralCompletionKeepsLatestModeAndSuspendsInputUntilReady() throws {
    let fixture = makeFixture(pageCount: 2)
    let view = fixture.view
    let pageID = try XCTUnwrap(view.viewerDocument?.activePageID)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal(); view.dispose(); fixture.window.isHidden = true }
    let workerEntered = DispatchSemaphore(value: 0)
    view.documentCoordinator.pdfQueue.async {
      workerEntered.signal()
      releaseWorker.wait()
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let owner = try attachedDocument(view)
    let moving = try owner.movePage(fromIndex: 0, toIndex: 1)
    let session = try view.setMode(mode: .ink, options: nil)
    XCTAssertTrue(view.interaction.isInk)
    XCTAssertFalse(view.documentView.isUserInteractionEnabled)
    XCTAssertFalse(view.canvasView.drawingGestureRecognizer.isEnabled)

    releaseWorker.signal()
    _ = try awaitDocumentOperation(moving)
    try awaitViewerPageReady(view, pageID: pageID)
    XCTAssertEqual(view.viewerDocument?.activePageID, pageID)
    XCTAssertTrue(view.interaction.isInk)
    XCTAssertTrue(view.documentView.isUserInteractionEnabled)
    XCTAssertTrue(view.canvasView.drawingGestureRecognizer.isEnabled)
    let page = try awaitDocumentOperation(session.getPage(pageIndex: nil))
    XCTAssertNoThrow(try page.getInputTargets())
    let canvas = view.canvasView
    let canvasPoint = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    let pointInPDF = canvas.convert(canvasPoint, to: view.documentView)
    let inkHit = try XCTUnwrap(view.documentView.hitTest(pointInPDF, with: nil))
    XCTAssertTrue(inkHit === canvas || inkHit.isDescendant(of: canvas))
    _ = try view.setMode(mode: .view, options: nil)
    XCTAssertNil(canvas.hitTest(canvasPoint, with: nil))
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

  func testAttachmentReadinessRequiresTheSameConditionsAsViewportCommands() {
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

  func testExistingFocusRequestPreservesZoomWhenZoomIsOmitted() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    let initialZoom = fixture.view.documentView.scaleFactor

    fixture.view.interaction.viewport.applyViewport(request: .focus(CGPoint(x: 150, y: 200), zoom: nil))

    XCTAssertEqual(fixture.view.documentView.scaleFactor, initialZoom, accuracy: 0.0001)
  }

  func testProgrammaticPageSwitchCompletionDoesNotRetainView() {
    var completion: ((Result<PageInfo, Error>) -> Void)?
    weak var weakView: ViewerCanvas?

    autoreleasepool {
      let view = ViewerCanvas()
      weakView = view
      completion = view.programmaticPageSwitchCompletion()
    }

    XCTAssertNil(weakView)

    let info = PageInfo(tag: nil, hasInk: false, hasText: false, pageIndex: 1, pageCount: 2, isDirty: false, pageId: "target",
      width: 612, height: 792, rotation: 0, canUndo: false, canRedo: false)
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
