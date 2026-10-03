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
      id: "coordinator-dirty",
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
    XCTAssertNotNil(InkSignPdfKeyRuleSelector.select(
      matches: lookup.matches,
      rules: analysis.rules,
      occurrence: .first,
      directionRtl: view.textInteractionOverlay.resolvedDirection(nil),
      pageSize: analysis.pageSize),
      "Fixture must contain a usable same-row rule; matches=\(lookup.matches), rules=\(analysis.rules)")

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let inserted = expectation(description: "captured-page key text commits")
    var insertionError: Error?
    let insertion = try view.insertTextByFieldName(text: "filled", key: "Name", options: nil)
    insertion.then { _ in inserted.fulfill() }
    insertion.catch { error in insertionError = error; inserted.fulfill() }

    XCTAssertEqual(try view.switchPage(to: 1).pageIndex, 1)
    XCTAssertEqual(coordinator.document?.activePageIndex, 1)
    releaseWorker.signal()
    wait(for: [inserted], timeout: 10)

    XCTAssertNil(insertionError)
    XCTAssertEqual(coordinator.document?.activePageIndex, 1)
    XCTAssertEqual(coordinator.document?.pages[0].history.content.textAnnotations.map(\.text), ["filled"])
    XCTAssertTrue(coordinator.document?.pages[1].history.content.textAnnotations.isEmpty == true)
  }

  func testManualPlacementSupersedesPendingFieldFocus() throws {
    let fixture = makeFixture(pageCount: 1)
    let keyPDFURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignFieldFocus-\(UUID().uuidString).pdf")
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
    let coordinator = view.documentCoordinator
    let opened = expectation(description: "field-focus fixture opens")
    var openError: Error?
    let openPromise = Promise<PageInfo>()
    openPromise.then { _ in opened.fulfill() }
    openPromise.catch { error in openError = error; opened.fulfill() }
    view.beginLoad(keyPDFURL.path, zoom: nil, focus: nil, fitToPage: true, promise: openPromise)
    wait(for: [opened], timeout: 5)
    XCTAssertNil(openError)
    coordinator.pdfQueue.sync {}

    let workerEntered = DispatchSemaphore(value: 0)
    let releaseWorker = DispatchSemaphore(value: 0)
    defer { releaseWorker.signal() }
    coordinator.pdfQueue.async {
      workerEntered.signal()
      _ = releaseWorker.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(workerEntered.wait(timeout: .now() + 2), .success)

    let settled = expectation(description: "superseded field focus settles")
    var focusError: Error?
    let focus = try view.focusPageByFieldName(key: "Name",
      options: FieldFocusOptions(occurrence: nil, zoom: 3, enterEditMode: true))
    focus.then { _ in settled.fulfill() }
    focus.catch { error in focusError = error; settled.fulfill() }

    try view.insertAnnotationOn(options: nil)
    XCTAssertTrue(view.textInteractionOverlay.hasPendingPlacement())
    let placementViewport = try view.currentViewportSnapshot()
    releaseWorker.signal()
    wait(for: [settled], timeout: 10)

    XCTAssertTrue(focusError?.localizedDescription.hasPrefix("operation_cancelled") == true)
    XCTAssertTrue(view.textInteractionOverlay.hasPendingPlacement())
    XCTAssertFalse(view.editMode)
    XCTAssertEqual(try view.currentViewportSnapshot().zoom, placementViewport.zoom)
    XCTAssertTrue(coordinator.document?.activePage.history.content.textAnnotations.isEmpty == true)
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

    let lookup = try view.insertTextByFieldName(text: "filled", key: "Name", options: nil)
    let lookupCancelled = expectation(description: "text lookup cancellation settles promptly")
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
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(secondOutput)))
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
