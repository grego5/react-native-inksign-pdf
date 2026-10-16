import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PencilKit
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
    _ = try awaitValue(core.open(sourceURL: source))
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
    _ = try awaitValue(core.open(sourceURL: source))
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
    _ = try awaitValue(core.open(sourceURL: source, tag: "report"))
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

  func testNormalCloseDrainsAdmittedOpenAndExportAndRejectsNewCommands() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    let gate = DispatchSemaphore(value: 0)
    core.coordinator.pdfQueue.async { gate.wait() }
    let opening = core.open(sourceURL: source)
    let exporting = core.finalize()
    let closing = core.close()
    XCTAssertThrowsError(try core.state())
    let rejected = core.open(sourceURL: source)
    gate.signal()
    _ = try awaitValue(opening)
    let uri = try awaitValue(exporting)
    let output = try XCTUnwrap(URL(string: uri))
    defer { try? FileManager.default.removeItem(at: output) }
    _ = try awaitValue(closing)
    XCTAssertThrowsError(try awaitValue(rejected))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testPageIdentityTargetsAndTagsSurviveImportReorderAndRotation() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared)
    defer { core.dispose() }
    _ = try awaitValue(core.open(sourceURL: source, tag: " "))
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
    _ = try awaitValue(reopened.open(sourceURL: output))
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
      _ = try awaitValue(core.open(sourceURL: source))
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

  func testDocumentAttachmentDetachesWithoutEndingOwnerOrHistory() throws {
    let source = try fixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let core = DocumentCore(artifactPolicy: .shared, recordHistory: true)
    defer { core.dispose() }
    _ = try awaitValue(core.open(sourceURL: source))
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
    _ = try awaitValue(core.open(sourceURL: source))
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
}
