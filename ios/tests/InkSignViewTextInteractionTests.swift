import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewTextInteractionTests: XCTestCase, InkSignViewTestSupport {
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

    do {
      try InkSignPdfNativeExporter.write(sourceURL: state.workingURL,
                                         pages: [snapshot],
                                         outputURL: output)
    } catch {
      if let pdfData = try? Data(contentsOf: output) {
        let attachment = XCTAttachment(data: pdfData,
                                       uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "native-ios-export-validation-failure.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      throw error
    }

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

}
