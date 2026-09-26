import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewLifecycleTests: XCTestCase, InkSignViewTestSupport {
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
      current: state.pages, activePageID: ids[1], mutation: .append([appended]))
    XCTAssertEqual(appendedOrder.pages.map(\.id), ids + [appended.id])
    XCTAssertEqual(appendedOrder.activePageID, appended.id)
    XCTAssertEqual(appendedOrder.addedPageCount, 1)

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

  func testMoveAndRemoveCommandsPublishFinalPageOrder() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let movedID = original.activePageID
    let annotation = makeCenteredTextAnnotation(
      id: "moved-page", text: "kept", fontSize: 18,
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
      let outputURL = URL(fileURLWithPath: path)
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
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    coordinator.settle(structural, succeeded: false)
    coordinator.settle(open, succeeded: false)
    XCTAssertNotNil(coordinator.document)
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
    XCTAssertNotNil(view.documentCoordinator.document)
    XCTAssertFalse(view.documentCoordinator.isCurrent(firstOperation))
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
    let originalCanvas = try XCTUnwrap(view.overlayProvider.canvasView(for: original.activePage.id))
    let rejected = expectation(description: "invalid replacement is rejected")
    var rejection: Error?
    let promise = Promise<PageInfo>()
    promise.catch { error in
      rejection = error
      rejected.fulfill()
    }

    view.beginLoad("", zoom: nil, focus: nil, fitToPage: true,
                   promise: promise)
    XCTAssertTrue(view.documentCoordinator.document === original)
    XCTAssertTrue(view.overlayProvider.canvasView(for: original.activePage.id) === originalCanvas)
    XCTAssertTrue(view.editMode)
    wait(for: [rejected], timeout: 5)

    XCTAssertNotNil(rejection)
    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.attachedOverlayPage)
    XCTAssertFalse(view.editMode)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.workingURL.path))
  }

  func testUnreadableReplacementClearsViewModePresentation() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let original = try XCTUnwrap(view.documentCoordinator.document)
    let originalCanvas = try XCTUnwrap(view.overlayProvider.canvasView(for: original.activePage.id))
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("invalid-\(UUID().uuidString).pdf")
    try Data("not a PDF".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let rejected = expectation(description: "unreadable replacement is rejected")
    let promise = Promise<PageInfo>()
    promise.catch { _ in rejected.fulfill() }
    view.beginLoad(source.path, zoom: nil, focus: nil, fitToPage: true, promise: promise)
    XCTAssertTrue(view.documentCoordinator.document === original)
    XCTAssertTrue(view.overlayProvider.canvasView(for: original.activePage.id) === originalCanvas)
    XCTAssertFalse(view.editMode)
    wait(for: [rejected], timeout: 5)

    XCTAssertNil(view.documentCoordinator.document)
    XCTAssertNil(view.documentView.document)
    XCTAssertNil(view.attachedOverlayPage)
    XCTAssertFalse(view.editMode)
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
    let operation = try XCTUnwrap(fixture.view.documentCoordinator.admit(.open))
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
    XCTAssertEqual(stateEventCount, 0)

    fixture.view.pendingOpen?.phase = .awaitingReadiness
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])

    XCTAssertEqual(fixture.view.documentView.scaleFactor, 2, accuracy: 0.0001)
    XCTAssertEqual(resolutionCount, 1)
    XCTAssertEqual(rejectionCount, 0)
    XCTAssertEqual(stateEventCount, 1)
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
