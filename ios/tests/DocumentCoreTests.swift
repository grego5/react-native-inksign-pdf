import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PencilKit
import PhotosUI
import NitroModules
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class DocumentCoreTests: XCTestCase, InkSignViewTestSupport {
  func testRejectedTextWritesPreserveDraftAndHistory() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    let page = try XCTUnwrap(core.coordinator.document?.pages.first)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: page.id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 24, y: 80, width: 200, height: 60)))
    try core.setTextValue(context, id: id, text: "before")
    let baseline = try XCTUnwrap(page.history.text(for: UInt64(id)))
    let edit = try core.beginTextEdit(context, id: UInt64(id))
    try core.updateTextEdit(edit, annotation: baseline.replacingText("draft", pageSize: page.geometry.displaySize))
    let revision = page.history.revision
    var ended = 0
    let observer = core.observe { if case .editEnded = $0 { ended += 1 } }
    defer { core.removeObserver(observer) }
    let invalidOptions = [
      TextAnnotationOptions(untracked: nil, font: .second("not-loaded"), fontSize: nil,
        color: nil, direction: nil, maxLines: nil, alignment: nil, verticalAnchor: nil),
      TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil,
        color: nil, direction: nil, maxLines: 1e20, alignment: nil, verticalAnchor: nil)
    ]
    for options in invalidOptions {
      XCTAssertThrowsError(try core.setTextValue(context, id: id, text: "replacement", options: options))
      XCTAssertThrowsError(try core.setTextOptions(context, id: id, options: options))
      XCTAssertTrue(core.activeTextEdit === edit)
      XCTAssertTrue(edit.active)
      XCTAssertEqual(try core.textValue(context, id: id), "draft")
      XCTAssertEqual(page.history.revision, revision)
      XCTAssertEqual(ended, 0)
    }
    try core.setTextValue(context, id: id, text: "accepted")
    XCTAssertFalse(edit.active)
    XCTAssertEqual(ended, 1)
    try core.undo(context)
    XCTAssertEqual(try core.textValue(context, id: id), "draft")
    try core.undo(context)
    XCTAssertEqual(try core.textValue(context, id: id), "before")
  }

  func testDeletedPageCommandsPreserveAnotherPagesDraft() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    _ = try awaitValue(core.addPages(sources: [source.absoluteString], imageGeometry: nil,
      targetDpi: nil, jpegQuality: nil, tag: nil))
    let state = try XCTUnwrap(core.coordinator.document)
    let stale = HybridDocumentPage(core: core, context: .init(generation: core.coordinator.generation,
      pageID: state.pages[1].id))
    _ = try awaitValue(core.mutatePage(index: 1))
    let page = try XCTUnwrap(core.coordinator.document?.pages.first)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: page.id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 24, y: 80, width: 200, height: 60)))
    try core.setTextValue(context, id: id, text: "before")
    let baseline = try XCTUnwrap(page.history.text(for: UInt64(id)))
    let edit = try core.beginTextEdit(context, id: UInt64(id))
    try core.updateTextEdit(edit, annotation: baseline.replacingText("draft", pageSize: page.geometry.displaySize))
    let revision = page.history.revision
    let commands: [() throws -> Void] = [stale.undo, stale.redo, stale.clear, stale.clearInk]
    for command in commands {
      XCTAssertThrowsError(try command())
      XCTAssertTrue(core.activeTextEdit === edit)
      XCTAssertTrue(edit.active)
      XCTAssertEqual(try core.textValue(context, id: id), "draft")
      XCTAssertEqual(page.history.revision, revision)
    }
  }

  func testHeadlessEditingExportAndCloseWithoutConstructingViewer() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source, tag: "report"))
    let state = try XCTUnwrap(core.coordinator.document)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: state.pages[0].id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 24, y: 80, width: 200, height: 60)))
    try core.setTextValue(context, id: id, text: "Ada")
    XCTAssertEqual(try core.textValue(context, id: id), "Ada")
    let info = try core.pageInfo(context)
    XCTAssertTrue(info.hasText)
    XCTAssertFalse(info.isDirty)
    XCTAssertFalse(info.canUndo)
    XCTAssertEqual(try core.pageIDs(tag: "report"), [info.pageId])
    let uri = try awaitValue(core.finalize())
    let output = try XCTUnwrap(URL(string: uri))
    defer { try? FileManager.default.removeItem(at: output) }
    XCTAssertTrue((PDFDocument(url: output)?.page(at: 0)?.string ?? "").contains("Ada"))
    _ = try awaitValue(core.close())
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Successful output belongs to the caller")
    XCTAssertThrowsError(try core.textValue(context, id: id))
    XCTAssertThrowsError(try core.state())
    _ = try awaitValue(core.close())
  }

  func testNormalCloseDrainsInitialLoadAndExportAndRejectsNewCommands() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    let gate = DispatchSemaphore(value: 0)
    core.coordinator.pdfQueue.async { gate.wait() }
    let opening = initializeDocument(core, from: source)
    let exporting = core.finalize()
    let closing = core.close()
    XCTAssertThrowsError(try core.state())
    let rejected = initializeDocument(core, from: source)
    gate.signal()
    _ = try awaitValue(opening)
    let uri = try awaitValue(exporting)
    let output = try XCTUnwrap(URL(string: uri))
    defer { try? FileManager.default.removeItem(at: output) }
    _ = try awaitValue(closing)
    XCTAssertThrowsError(try awaitValue(rejected))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testPickerCancellationPreservesTextDraftHistoryAndEvents() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    var actions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    let inputs = InkSignPdfPageInputCoordinator(artifactPolicy: .shared,
      presenterProvider: { [UIViewController()] },
      controllerPresenter: { _, _ in },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, value in actions = value; return UIViewController() },
      securityScope: { _, copy in try copy() })
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true, inputCoordinator: inputs)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    let page = try XCTUnwrap(core.coordinator.document?.pages.first)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: page.id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 24, y: 80, width: 200, height: 60)))
    try core.setTextValue(context, id: id, text: "committed")
    let committed = try XCTUnwrap(page.history.text(for: UInt64(id)))
    let edit = try core.beginTextEdit(context, id: UInt64(id))
    try core.updateTextEdit(edit, annotation: committed.replacingText("draft", pageSize: page.geometry.displaySize))
    let revision = page.history.revision
    var events: [DocumentCore.Change] = []
    let observer = core.observe { events.append($0) }
    defer { core.removeObserver(observer) }

    let add = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: nil, type: nil)
    XCTAssertNotNil(actions)
    actions?.cancel()
    XCTAssertEqual(try awaitValue(add), 0)

    XCTAssertTrue(edit.active)
    XCTAssertTrue(core.activeTextEdit === edit)
    XCTAssertEqual(try core.textValue(context, id: id), "draft")
    XCTAssertEqual(page.history.text(for: UInt64(id))?.text, "draft")
    XCTAssertEqual(page.history.revision, revision)
    XCTAssertEqual(core.coordinator.document?.pages.count, 1)
    XCTAssertFalse(events.contains { if case .structuralWriteStarted = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .structure = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .page = $0 { return true }; return false })
  }

  func testPickerSelectionKeepsQueuedRotationBehindImport() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    var actions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    var picker: UIDocumentPickerViewController?
    let inputs = InkSignPdfPageInputCoordinator(artifactPolicy: .shared,
      presenterProvider: { [UIViewController()] },
      documentPickerFactory: { UIDocumentPickerViewController(forOpeningContentTypes: $0, asCopy: false) },
      controllerPresenter: { _, controller in picker = controller as? UIDocumentPickerViewController },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, value in actions = value; return UIViewController() },
      securityScope: { _, copy in try copy() })
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true, inputCoordinator: inputs)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    var events: [DocumentCore.Change] = []
    let observer = core.observe { events.append($0) }
    defer { core.removeObserver(observer) }

    let adding = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: "selected", type: nil)
    let rotating = core.rotatePage(index: 0, degrees: 90)
    XCTAssertNotNil(actions)
    XCTAssertEqual(core.coordinator.document?.pages.first?.geometry.rotation, 0)
    XCTAssertFalse(events.contains { if case .structuralWriteStarted = $0 { return true }; return false })

    onMain { actions?.chooseFiles() }
    let selectedPicker = try XCTUnwrap(picker)
    onMain { inputs.documentPicker(selectedPicker, didPickDocumentsAt: [source]) }
    XCTAssertEqual(try awaitValue(adding), 1)
    try awaitValue(rotating)
    XCTAssertEqual(core.coordinator.document?.pages.count, 2)
    XCTAssertEqual(core.coordinator.document?.pages.first?.geometry.rotation, 90)
    XCTAssertTrue(core.coordinator.document?.pages.last?.tag == "selected")
  }

  func testQueuedPickerStartsOnlyAfterPreviousPickerDismisses() async throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    var actions: InkSignPdfPageInputCoordinator.SourceChoiceActions?
    var pickers: [PHPickerViewController] = []
    var pendingDismissals: [() -> Void] = []
    var presentations = 0
    let secondPresentation = InkSignPdfOperationPromise<Void>()
    let inputs = InkSignPdfPageInputCoordinator(artifactPolicy: .shared,
      presenterProvider: { [UIViewController()] },
      controllerPresenter: { _, controller in
        if let picker = controller as? PHPickerViewController { pickers.append(picker) }
      },
      controllerDismisser: { controller, _, completion in
        if controller is PHPickerViewController, let completion {
          pendingDismissals.append(completion)
        } else { completion?() }
      },
      sourceChooser: { _, value in
        actions = value
        presentations += 1
        if presentations == 2 { secondPresentation.resolve(()) }
        return UIViewController()
      })
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true, inputCoordinator: inputs)
    defer {
      core.dispose()
      while !pendingDismissals.isEmpty { pendingDismissals.removeFirst()() }
    }
    _ = try await awaitValueAsync(initializeDocument(core, from: source))
    let first = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: nil, type: .image)
    let second = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: nil, type: .image)
    var firstResult: Int?
    first.then { firstResult = $0 }

    onMain { actions?.choosePhotos() }
    let firstPicker = try XCTUnwrap(pickers.first)
    onMain { inputs.finishPhotoPicking(itemProviders: [], from: firstPicker) }
    XCTAssertNil(firstResult, "Cancellation waits for actual picker dismissal")
    XCTAssertEqual(presentations, 1, "The FIFO still belongs to the dismissing picker")
    XCTAssertEqual(pendingDismissals.count, 1, "Selection and settlement share one dismissal")

    onMain { pendingDismissals.removeFirst()() }
    let firstResultValue = try await awaitValueAsync(first)
    XCTAssertEqual(firstResultValue, 0)
    try await awaitValueAsync(secondPresentation.promise)
    XCTAssertEqual(presentations, 2)
    onMain { actions?.choosePhotos() }
    let secondPicker = try XCTUnwrap(pickers.last)
    XCTAssertFalse(firstPicker === secondPicker)
    onMain { inputs.finishPhotoPicking(itemProviders: [], from: secondPicker) }
    XCTAssertEqual(pendingDismissals.count, 1)
    onMain { pendingDismissals.removeFirst()() }
    let secondResultValue = try await awaitValueAsync(second)
    XCTAssertEqual(secondResultValue, 0)
    XCTAssertEqual(core.coordinator.document?.pages.count, 1)
  }

  func testCloseCancelsWaitingAndQueuedPickerWithoutLaunchingSecondSelection() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    var presentations = 0
    let inputs = InkSignPdfPageInputCoordinator(artifactPolicy: .shared,
      presenterProvider: { [UIViewController()] },
      controllerPresenter: { _, _ in },
      controllerDismisser: { _, _, completion in completion?() },
      sourceChooser: { _, _ in presentations += 1; return UIViewController() },
      securityScope: { _, copy in try copy() })
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true, inputCoordinator: inputs)
    _ = try awaitValue(initializeDocument(core, from: source))
    let waiting = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: nil, type: nil)
    let queued = core.addPages(sources: nil, imageGeometry: nil, targetDpi: nil,
      jpegQuality: nil, tag: nil, type: nil)
    let closing = core.close()

    XCTAssertThrowsError(try awaitValue(waiting)) { error in
      XCTAssertTrue(error.localizedDescription.hasPrefix("operation_cancelled:"))
    }
    XCTAssertThrowsError(try awaitValue(queued)) { error in
      XCTAssertTrue(error.localizedDescription.hasPrefix("operation_cancelled:"))
    }
    try awaitValue(closing)
    XCTAssertEqual(presentations, 1)
  }

  func testCloseWaitsForDirectSourceCopyAndPublishesWithoutViewer() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let inputs = InkSignPdfPageInputCoordinator(artifactPolicy: .shared,
      presenterProvider: { [] },
      securityScope: { _, copy in
        entered.signal()
        guard release.wait(timeout: .now() + 10) == .success else {
          throw InkSignPdfPageInputCoordinator.PageInputError.operationCancelled
        }
        return try copy()
      })
    let core = DocumentCore(artifactPolicy: .shared, inputCoordinator: inputs)
    defer { release.signal(); core.dispose() }

    let opening = initializeDocument(core, from: source)
    XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
    var closed = false
    let closing = core.close()
    closing.then { closed = true }
    XCTAssertFalse(closed, "Close waits for an admitted direct-source copy")
    release.signal()
    let state = try awaitValue(opening)
    XCTAssertEqual(state, 1)
    try awaitValue(closing)
    XCTAssertTrue(closed)
  }

  func testPageIdentityTargetsAndTagsSurviveImportReorderAndRotation() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source, tag: " "))
    let original = try XCTUnwrap(core.coordinator.document?.pages.first)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: original.id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 24, y: 80, width: 200, height: 60)))
    let added = try awaitValue(core.addPages(sources: [source.absoluteString, source.absoluteString],
      imageGeometry: nil, targetDpi: nil, jpegQuality: nil, tag: "attachment"))
    XCTAssertEqual(added, 2)
    let importedIDs = try core.pageIDs(tag: "attachment")
    XCTAssertEqual(importedIDs.count, 2)
    _ = try awaitValue(core.mutatePage(index: 0, destination: 2))
    XCTAssertEqual(try core.pageInfo(context).pageIndex, 2)
    XCTAssertEqual(try core.pageIDs(tag: " "), [original.id.uuidString])
    XCTAssertEqual(try core.pageIDs(tag: "attachment"), importedIDs)
    _ = try awaitValue(core.rotatePage(index: 2, degrees: 180))
    let rotated = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: .init(x: 76, y: 260, width: 200, height: 60)))
    XCTAssertEqual(rotated, id)
    try core.setTextValue(context, id: id, text: "Upright")
    XCTAssertEqual(try core.textValue(context, id: id), "Upright")
    XCTAssertEqual(try core.pageInfo(context).rotation, 180)
    _ = try awaitValue(core.mutatePage(index: 0))
    XCTAssertEqual(try core.pageInfo(context).pageIndex, 1)
    XCTAssertEqual(try core.pageIDs(tag: "attachment"), [importedIDs[1]])
    let output = try XCTUnwrap(URL(string: try awaitValue(core.finalize())))
    defer { try? FileManager.default.removeItem(at: output) }
    let reopened = DocumentCore(artifactPolicy: .shared)
    defer { reopened.dispose() }
    _ = try awaitValue(initializeDocument(reopened, from: output))
    XCTAssertTrue(try reopened.pageIDs(tag: " ").isEmpty)
    XCTAssertTrue(try reopened.pageIDs(tag: "attachment").isEmpty)
  }

  func testIndependentBaseTextSurvivesUndoAndClearWhileRetainedTextStaysTracked() {
    let history = InkSignPdfPageContentHistory()
    let first = text(id: 1, value: "Tracked")
    XCTAssertTrue(history.appendText(first))
    XCTAssertTrue(history.undo())
    let base = text(id: 2, value: "Base")
    XCTAssertTrue(history.appendText(base, untracked: true))
    XCTAssertTrue(history.canRedo)
    XCTAssertFalse(history.state.isDirty)
    XCTAssertTrue(history.redo())
    let updated = first.replacingText("Changed", pageSize: CGSize(width: 300, height: 400))
    XCTAssertTrue(history.replaceText(before: first, with: updated, type: .textEdit, untracked: true))
    XCTAssertEqual(history.undoStack.count, 2)
    history.clear()
    XCTAssertTrue(history.content.isEmpty)
    XCTAssertTrue(history.undo())
    XCTAssertTrue(history.content.textAnnotations.contains(base))
    XCTAssertTrue(history.undo())
    XCTAssertTrue(history.content.textAnnotations.contains(first))
    XCTAssertTrue(history.undo())
    XCTAssertEqual(history.content.textAnnotations, [base])
    XCTAssertFalse(history.state.isDirty)
  }

  func testNamedFontBatchFailureDoesNotPublishEarlierCandidate() throws {
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    let resources = InkSignPdfCoreTextExportResources()
    _ = try resources.prepare(text(id: 1, value: "Static face"), pageSize: CGSize(width: 300, height: 400))
    let bytes = try XCTUnwrap(resources.fonts.first)
    let valid = FileManager.default.temporaryDirectory.appendingPathComponent("font-\(UUID().uuidString).ttf")
    let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("font-\(UUID().uuidString).ttf")
    defer { try? FileManager.default.removeItem(at: valid); try? FileManager.default.removeItem(at: invalid) }
    try bytes.write(to: valid)
    try Data([0, 1, 2]).write(to: invalid)
    XCTAssertThrowsError(try awaitValue(core.loadFontSources([
      InkSignPdfNamedFontRegistry.Source(name: "Valid", uri: valid.absoluteString),
      InkSignPdfNamedFontRegistry.Source(name: "Invalid", uri: invalid.absoluteString)
    ])))
    XCTAssertThrowsError(try core.fonts.resolveSelection(.named("Valid")))
    _ = try awaitValue(core.loadFontSources([InkSignPdfNamedFontRegistry.Source(name: "Valid", uri: valid.absoluteString)]))
    XCTAssertNotNil(try core.fonts.resolveSelection(.named("Valid")))
    _ = try awaitValue(core.loadFontSources([InkSignPdfNamedFontRegistry.Source(name: "Alias", uri: valid.absoluteString)]))
    XCTAssertTrue(try core.fonts.resolveSelection(.named("Valid")) === core.fonts.resolveSelection(.named("Alias")))
    XCTAssertThrowsError(try awaitValue(core.loadFontSources([InkSignPdfNamedFontRegistry.Source(name: "Valid", uri: invalid.absoluteString)])))
    XCTAssertNotNil(try core.fonts.resolveSelection(.named("Valid")))
  }

  func testCroppedPagesPreserveVisibleCoordinatesThroughRotationAndExport() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let pdf = try XCTUnwrap(PDFDocument(url: source))
    let sourcePage = try XCTUnwrap(pdf.page(at: 0))
    let crop = CGRect(x: 12, y: 24, width: 264, height: 352)
    sourcePage.setBounds(crop, for: .cropBox)
    XCTAssertTrue(pdf.write(to: source))
    for rotation in [0, 90, 180, 270] {
      let core = DocumentCore(artifactPolicy: .shared)
      defer { core.dispose() }
      _ = try awaitValue(initializeDocument(core, from: source))
      if rotation != 0 { _ = try awaitValue(core.rotatePage(index: 0, degrees: rotation)) }
      let page = try XCTUnwrap(core.coordinator.document?.pages.first)
      let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: page.id)
      XCTAssertEqual(page.geometry.mediaBox, CGRect(x: 0, y: 0, width: 300, height: 400))
      XCTAssertEqual(page.geometry.visibleBox, crop)
      let info = try core.pageInfo(context)
      XCTAssertEqual(info.width, Double(rotation % 180 == 0 ? crop.width : crop.height))
      XCTAssertEqual(info.height, Double(rotation % 180 == 0 ? crop.height : crop.width))
      let bounds = CGRect(x: 24, y: 80, width: 120, height: 40)
      let id = try core.resolveText(context, options: InputTargetResolutionOptions(bounds: bounds))
      try core.setTextValue(context, id: id, text: "CropValue")
      let output = try XCTUnwrap(URL(string: try awaitValue(core.finalize())))
      defer { try? FileManager.default.removeItem(at: output) }
      let exported = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
      XCTAssertEqual(exported.bounds(for: .mediaBox), page.geometry.mediaBox)
      XCTAssertEqual(exported.bounds(for: .cropBox), crop)
      let text = try XCTUnwrap(exported.string) as NSString
      let range = text.range(of: "CropValue")
      XCTAssertNotEqual(range.location, NSNotFound)
      let selection = try XCTUnwrap(exported.selection(for: range))
      let expected = bounds.applying(page.geometry.displayToPDFTransform)
      XCTAssertTrue(expected.contains(selection.bounds(for: exported)),
        "Exported text must stay inside its physical visible-page target at rotation \(rotation)")
    }
  }

  func testInitialSourcesLoadBeforePageCommandsAndRemainClean() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let document = try HybridInkSignDocumentFactory().createDocument(options: DocumentOptions(
      type: nil, recordHistory: nil, tag: "initial", imagePageSize: nil, targetDpi: nil,
      jpegQuality: nil, androidFallbackFont: nil, sources: [source.path]))
    defer { if let document = document as? HybridInkSignDocument { document.core.dispose() } }
    let page = try awaitValue(document.getPage(index: .first(0)))
    XCTAssertEqual(try page.getState().tag, "initial")
    XCTAssertEqual(try document.getState().pageCount, 1)
    XCTAssertFalse(try document.getState().isDirty)
    _ = try awaitValue(document.close())
  }

  func testInitialSourceFailureReachesViewerAndQueuedReadWhileCloseStillWorks() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).pdf").path
    let document = try XCTUnwrap(try HybridInkSignDocumentFactory().createDocument(options: DocumentOptions(
      type: nil, recordHistory: nil, tag: nil, imagePageSize: nil, targetDpi: nil,
      jpegQuality: nil, androidFallbackFont: nil, sources: [path])) as? HybridInkSignDocument)
    defer { document.core.dispose() }
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    fixture.view.document = document
    XCTAssertThrowsError(try awaitValue(document.getPage(index: .first(0)))) { error in
      XCTAssertEqual(error.localizedDescription, document.core.initializationError?.localizedDescription)
      XCTAssertEqual(error.localizedDescription, fixture.view.loadError)
    }
    XCTAssertTrue(fixture.view.document as? HybridInkSignDocument === document)
    _ = try awaitValue(document.close())
  }

  func testEmptyDocumentPopulatesAnAttachedViewerAndSurvivesDetach() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let document = try XCTUnwrap(try HybridInkSignDocumentFactory().createDocument(options: nil)
      as? HybridInkSignDocument)
    defer { document.core.dispose() }
    let view = ViewerCanvas()
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    defer { view.dispose(); window.isHidden = true }
    view.document = document
    XCTAssertNil(view.viewerDocument)
    XCTAssertEqual(try document.getState().pageCount, 0)
    var events: [PageChangeEvent] = []
    view.onPageChange = { events.append($0) }
    let unchanged = try awaitValue(document.addPages(options: DocumentAddPagesOptions(
      type: nil, tag: nil, sources: [], imagePageSize: nil, targetDpi: nil, jpegQuality: nil)))
    XCTAssertEqual(unchanged.addedPageCount, 0)
    XCTAssertTrue(events.isEmpty)
    let added = try awaitValue(document.addPages(options: DocumentAddPagesOptions(
      type: nil, tag: "first", sources: [source.path], imagePageSize: nil, targetDpi: nil, jpegQuality: nil)))
    XCTAssertEqual(added.pageCount, 1)
    let page = try XCTUnwrap(document.core.coordinator.document?.pages.first)
    try awaitViewerPageReady(view, pageID: page.id, timeout: 120)
    XCTAssertEqual(events.last?.pageId, page.id.uuidString)
    XCTAssertTrue(try document.getState().isDirty)
    view.document = nil
    XCTAssertEqual(document.pageCount, 1)
    _ = try awaitValue(document.close())
  }

  func testPageCallbackRegisteredAfterAttachmentReceivesCurrentSnapshot() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let page = try XCTUnwrap(fixture.view.viewerDocument?.activePage)
    fixture.view.emitChange(force: true)
    var events: [PageChangeEvent] = []
    fixture.view.onPageChange = { events.append($0) }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.pageId, page.id.uuidString)
    fixture.view.emitChange(force: true)
    XCTAssertEqual(events.count, 1, "Unchanged snapshots remain suppressed")
    var replacementEvents: [PageChangeEvent] = []
    fixture.view.onPageChange = { replacementEvents.append($0) }
    XCTAssertEqual(replacementEvents.count, 1)
    XCTAssertEqual(replacementEvents.first?.pageId, page.id.uuidString)
  }

  func testDocumentAttachmentDetachesWithoutEndingOwnerOrHistory() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    let document = HybridInkSignDocument(core: core)
    let page = try XCTUnwrap(core.coordinator.document?.pages.first)
    let context = InkSignPdfCorePageContext(generation: core.coordinator.generation, pageID: page.id)
    let id = try core.resolveText(context, options: InputTargetResolutionOptions(
      bounds: CGRect(x: 24, y: 80, width: 200, height: 60)))
    try core.setTextValue(context, id: id, text: "Before attachment")
    let first = makeFixture(pageCount: 1)
    defer { first.view.dispose(); first.window.isHidden = true }
    first.view.document = document
    XCTAssertTrue(first.view.viewerDocument?.core === core.coordinator.document)
    XCTAssertTrue(try core.pageInfo(context).canUndo)
    first.view.document = nil
    XCTAssertNil(first.view.viewerDocument)
    XCTAssertEqual(try core.textValue(context, id: id), "Before attachment")
    first.view.dispose()
    try core.setTextValue(context, id: id, text: "After unmount")
    let second = makeFixture(pageCount: 1)
    defer { second.view.dispose(); second.window.isHidden = true }
    second.view.document = document
    XCTAssertTrue(second.view.viewerDocument?.core === core.coordinator.document)
    XCTAssertEqual(try core.textValue(context, id: id), "After unmount")
    XCTAssertEqual(try core.pageInfo(context).pageId, page.id.uuidString)
    _ = try awaitValue(document.close())
    XCTAssertNil(second.view.viewerDocument)
    XCTAssertThrowsError(try core.textValue(context, id: id))
  }

  func testDocumentRejectsSecondViewerUntilFirstDetaches() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    defer { core.dispose() }
    _ = try awaitValue(initializeDocument(core, from: source))
    let document = HybridInkSignDocument(core: core)
    let first = makeFixture(pageCount: 1)
    let second = makeFixture(pageCount: 1)
    let secondOriginalDocument = try XCTUnwrap(second.view.document as? HybridInkSignDocument)
    defer {
      first.view.dispose(); first.window.isHidden = true
      second.view.dispose(); second.window.isHidden = true
    }
    first.view.document = document
    second.view.document = document
    XCTAssertTrue(second.view.document as? HybridInkSignDocument === secondOriginalDocument)
    XCTAssertTrue(second.view.loadError?.hasPrefix("document_already_attached") == true)
    first.view.document = nil
    second.view.document = document
    XCTAssertNotNil(second.view.document)
    XCTAssertNil(second.view.loadError)
  }

  private func text(id: UInt64, value: String) -> InkSignPdfTextAnnotation {
    InkSignPdfTextAnnotation(id: id, text: value, bounds: CGRect(x: 24, y: 80, width: 200, height: 60), fontSize: 16)
  }
  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID().uuidString).pdf")
    try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).writePDF(to: url) { renderer in
      renderer.beginPage()
      let font = CTFontCreateWithName("ArialMT" as CFString, 16, nil)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Source", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]))
      renderer.cgContext.textPosition = CGPoint(x: 24, y: 350)
      CTLineDraw(line, renderer.cgContext)
    }
    return url
  }
  private func awaitValue<Value>(_ promise: Promise<Value>) throws -> Value {
    let completed = expectation(description: "core operation settles")
    var result: Result<Value, Error>?
    promise.then { result = .success($0); completed.fulfill() }
    promise.catch { result = .failure($0); completed.fulfill() }
    // Hang watchdog, not a performance assertion; the Mac VM can stall scheduling.
    wait(for: [completed], timeout: 120)
    return try XCTUnwrap(result).get()
  }
  private func awaitValueAsync<Value>(_ promise: Promise<Value>) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      promise.then { continuation.resume(returning: $0) }
      promise.catch { continuation.resume(throwing: $0) }
    }
  }
  private func onMain(_ action: () -> Void) {
    if Thread.isMainThread { action() } else { DispatchQueue.main.sync(execute: action) }
  }
}
