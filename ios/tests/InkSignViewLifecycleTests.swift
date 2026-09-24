import CoreGraphics
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
      current: state.pages, activePageID: ids[1], mutation: .moveActive(to: 3))) { error in
      XCTAssertEqual(error as? InkSignPdfDocumentCoordinator.PageMutationError, .invalidPageIndex)
    }
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
      let pdf = PDFDocument(url: URL(fileURLWithPath: path))
      XCTAssertEqual(pdf?.pageCount, 2)
      XCTAssertEqual(pdf?.page(at: 0)?.bounds(for: .mediaBox).width, 300)
      XCTAssertEqual(pdf?.page(at: 0)?.bounds(for: .mediaBox).height, 400)
      XCTAssertEqual(pdf?.page(at: 1)?.bounds(for: .mediaBox).width, 500)
      XCTAssertEqual(pdf?.page(at: 1)?.bounds(for: .mediaBox).height, 400)
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

  func testFailedReplacementOpenRestoresStructuralDirtyState() throws {
    let fixture = makeFixture(pageCount: 2)
    let replacementFixture = makeFixture(pageCount: 1)
    defer {
      fixture.view.dispose(); fixture.window.isHidden = true
      replacementFixture.view.dispose(); replacementFixture.window.isHidden = true
    }
    let coordinator = fixture.view.documentCoordinator
    let original = try XCTUnwrap(coordinator.document)
    let replacement = try XCTUnwrap(replacementFixture.view.documentCoordinator.document)
    coordinator.setStructuralDirty(true)
    let operation = try XCTUnwrap(coordinator.admit(.open))

    XCTAssertTrue(coordinator.publish(replacement, operation: operation))
    XCTAssertFalse(coordinator.isDirty)
    coordinator.settle(operation, succeeded: false)

    XCTAssertTrue(coordinator.document === original)
    XCTAssertTrue(coordinator.structuralDirty)
    XCTAssertTrue(coordinator.isDirty)
  }

  func testReplacementOpenCancelsPendingOpen() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let firstOperation = try XCTUnwrap(view.documentCoordinator.admit(.open))
    let firstPromise = Promise<PageInfo>()
    var firstError: Error?
    firstPromise.catch { firstError = $0 }
    view.pendingOpen = InkSignView.PendingOpen(token: firstOperation.generation,
                                               operation: firstOperation,
                                               promise: firstPromise,
                                               zoom: nil,
                                               focus: nil,
                                               fitToPage: true)

    view.beginLoad("", zoom: nil, focus: nil, fitToPage: true,
                   promise: Promise<PageInfo>())

    XCTAssertNotNil(firstError)
    XCTAssertNil(view.pendingOpen)
    XCTAssertNotNil(view.documentCoordinator.document)
    XCTAssertFalse(view.documentCoordinator.isCurrent(firstOperation))
  }

  func testFailedReplacementRestoresViewportAndEditingMode() throws {
    let fixture = makeFixture()
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let target = ViewportTarget(zoom: 3, focus: CGPoint(x: 140, y: 180))
    XCTAssertTrue(view.applyViewport(target: target))
    view.setInteractionMode(editing: true)

    view.beginLoad("", zoom: nil, focus: nil, fitToPage: true,
                   promise: Promise<PageInfo>())

    let restored = try view.currentViewportSnapshot()
    XCTAssertEqual(restored.zoom, 3, accuracy: 0.0001)
    XCTAssertEqual(restored.x, 140, accuracy: 1)
    XCTAssertEqual(restored.y, 180, accuracy: 1)
    XCTAssertTrue(view.editMode)
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
    let loadedCandidate = try InkSignPdfDocumentCandidateLoader.load(url: candidateURL)
    let candidatePages = loadedCandidate.pages
    let candidate = InkSignPdfDocumentState(sourceURL: original.sourceURL,
                                            workingURL: candidateURL,
                                            document: loadedCandidate.document,
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
      operation: nil,
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
    let pageBounds = try XCTUnwrap(fixture.view.documentView.viewportTransform?.pageFrame)

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

    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testRepeatedStablePreviewReconciliationSubmitsOneRenderPerDirection() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    let initialSubmissionCount = fixture.previewScheduler.submittedRequests.count

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 1)
    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 1)
    fixture.previewScheduler.completeAll()
    XCTAssertNotNil(preparedPreview(.left, in: fixture.view))
  }

  func testTwoEligibleDirectionsEachRetainOneInFlightRequest() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    let initialSubmissionCount = fixture.previewScheduler.submittedRequests.count

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 2)
    XCTAssertNotNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 2)
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

  func testTextAnnotationKeepsCenteredIntrinsicBoundsWhenContentExceedsPage() {
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "one\n\ntwo",
      fontSize: 16,
      pageSize: CGSize(width: 80, height: 40))

    XCTAssertEqual(annotation.text, "one\n\ntwo")
    XCTAssertGreaterThan(annotation.intrinsicSize.height, 2 * 16)
    XCTAssertLessThanOrEqual(annotation.bounds.maxX, 80)
    XCTAssertGreaterThan(annotation.intrinsicSize.height, 40)
    XCTAssertEqual(annotation.bounds.midY, 20, accuracy: 0.001)
    XCTAssertEqual(annotation.bounds.maxY,
                   (40 + annotation.intrinsicSize.height) / 2,
                   accuracy: 0.001)
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

  func testNativeExporterShapesAndExportsLTRAndRTLText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let geometry = state.pages[0].geometry
    let latin = makeCenteredTextAnnotation(id: "latin", text: "Latin",
                                           fontSize: 18, pageSize: geometry.mediaBox.size)
    let rtl = InkSignPdfTextAnnotation(id: "rtl", text: "שלום",
                                       bounds: latin.bounds.offsetBy(dx: 0, dy: 30),
                                       fontSize: latin.fontSize,
                                       isRTL: true)
    let snapshot = ExportPageSnapshot(pageIndex: 0,
                                      pageID: state.pages[0].id,
                                      geometry: geometry,
                                      drawingData: PKDrawing().dataRepresentation(),
                                      textAnnotations: [latin, rtl])
    let policy = InkSignPdfCacheArtifactPolicy.shared
    let output = try policy.allocateExportScratch()
    defer { policy.deleteExact(output) }

    try InkSignPdfNativeExporter.write(sourceURL: state.workingURL,
                                       pages: [snapshot],
                                       outputURL: output)

    let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
    for expected in [latin, rtl] {
      let annotation = try XCTUnwrap(page.annotations.first {
        $0.contents == expected.text &&
          $0.type?.caseInsensitiveCompare("FreeText") == .orderedSame
      })
      XCTAssertTrue(annotation.hasAppearanceStream)
      let flags = InkSignPdfVectorAnnotation.flags(of: annotation)
      XCTAssertEqual(flags & InkSignPdfVectorAnnotation.textFlags,
                     InkSignPdfVectorAnnotation.textFlags)
    }
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
                        type: .textEdit)

    XCTAssertEqual(history.content.textAnnotations.count, 1)
    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate, .textEdit])
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
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.undoStack.map(\.type), [.textCreate])
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
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.undoStack.map(\.type), [.textCreate])
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

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -120, y: 0))
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
    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
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

  func testPageSwitchCompletesAfterRetainedOverlayHandoff() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      if case .failure(let error) = result {
        XCTFail("unexpected page switch failure: \(error)")
      }
    }

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testOverlayDetachmentAfterCommittedPageTurnDoesNotResettleIt() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
    let completedSwitchID = fixture.view.pageSwitchRequestID
    XCTAssertFalse(fixture.view.pageTurnLifecycle.pageSwitchReady(switchID: completedSwitchID &+ 1))
    fixture.view.pageTurnLifecycle.pageSwitchCancelled(switchID: completedSwitchID &+ 1)
    fixture.view.pageTurnLifecycle.pageSwitchFailed(switchID: completedSwitchID &+ 1)

    fixture.view.overlayDidEndDisplaying(fixture.view.canvasView, for: fixture.pages[1])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
  }

  func testCompletedPageSwitchIgnoresCancellationAndLateOverlayCallback() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    var switchResult: Result<PageInfo, Error>?

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      switchResult = result
    }

    fixture.view.cancelPendingPageSwitch()
    fixture.view.cancelPendingPageSwitch()
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    guard case .success(let pageInfo) = switchResult else {
      return XCTFail("the installed target page should complete successfully")
    }
    XCTAssertEqual(pageInfo.pageIndex, 1)
  }

  func testNewerQueuedPageNavigationPublishesOnlyItsResult() throws {
    let fixture = makeFixture(pageCount: 3)
    defer { fixture.window.isHidden = true }
    var pageChanges = [PageInfo]()
    fixture.view.onPageChange = { pageChanges.append($0) }

    try fixture.view.nextPage()
    try fixture.view.nextPage()
    drainMainQueue()

    XCTAssertEqual(pageChanges.map(\.pageIndex), [1])
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testDocumentReplacementInvalidatesQueuedPageNavigation() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }

    try fixture.view.nextPage()

    fixture.view.beginLoad(
      "",
      zoom: nil,
      focus: nil,
      fitToPage: true,
      promise: Promise<PageInfo>())
    drainMainQueue()

    XCTAssertEqual(completionCount, 0)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[0])
  }

  func testDisposalInvalidatesQueuedPageNavigation() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }

    try fixture.view.nextPage()

    fixture.view.dispose()
    fixture.view.dispose()
    drainMainQueue()

    XCTAssertEqual(completionCount, 0)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
  }

  private func makeFixture(
    pageCount: Int = 2,
    activePageIndex: Int = 0,
    applyInitialViewport: Bool = true
  ) -> (view: InkSignView, window: UIWindow, pages: [UUID],
        previewScheduler: TestPreviewScheduler,
        animationFactory: TestAnimationDriverFactory) {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 300 + index * 100, height: 400))
        .image { UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400)) }
      let page = PDFPage(image: image)!
      page.setBounds(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400), for: .mediaBox)
      document.insert(page, at: index)
    }
    let workingURL = try! InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    XCTAssertTrue(document.write(to: workingURL))
    let loaded = try! InkSignPdfDocumentCandidateLoader.load(url: workingURL)
    let states = loaded.pages
    let previewScheduler = TestPreviewScheduler()
    let animationFactory = TestAnimationDriverFactory()
    let view = InkSignView(
      previewScheduler: previewScheduler,
      animationDriverFactory: animationFactory)
    let state = InkSignPdfDocumentState(
      sourceURL: workingURL,
      workingURL: workingURL,
      document: loaded.document,
      pages: states)
    XCTAssertTrue(view.documentCoordinator.publish(state, generation: view.documentCoordinator.generation))
    XCTAssertTrue(view.documentCoordinator.selectPage(at: activePageIndex))
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    view.documentView.installPage(
      index: activePageIndex,
      pageID: states[activePageIndex].id,
      geometry: states[activePageIndex].geometry,
      page: states[activePageIndex].page,
      document: loaded.document,
      generation: view.documentCoordinator.generation)
    view.documentView.layoutIfNeeded()
    if applyInitialViewport {
      XCTAssertTrue(view.documentView.applyViewport(
        zoom: view.documentView.scaleFactorForSizeToFit,
        focus: CGPoint(x: 150, y: 200),
        generation: view.documentCoordinator.generation))
    }
    view.canvasView.frame = view.documentView.bounds
    view.attachedOverlayPage = states[activePageIndex].id
    view.overlayTransformPage = states[activePageIndex].id
    view.pageToOverlayTransform = .identity
    view.pageTurnLifecycle.stableContextChanged()
    previewScheduler.completeAll()
    return (view, window, states.map(\.id), previewScheduler, animationFactory)
  }

  private func drainMainQueue() {
    let drained = expectation(description: "queued navigation callbacks")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
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
