import CoreGraphics
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewStabilizationTests: XCTestCase, InkSignViewTestSupport {
  func testTextLayoutUsesExplicitLinesAndTrailingEmptyLine() {
    let metrics = InkSignPdfTextRenderer.layout(text: "wide\n\n",
                                                fontSize: 16,
                                                contentWidth: 300)

    XCTAssertEqual(metrics.size.width,
                   metrics.maximumLineWidth +
                     InkSignPdfTextStyle.presentationInsets.left +
                     InkSignPdfTextStyle.presentationInsets.right,
                   accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(metrics.size.height,
                                 metrics.lineHeight * 3 +
                                   InkSignPdfTextStyle.presentationInsets.top +
                                   InkSignPdfTextStyle.presentationInsets.bottom)
    XCTAssertGreaterThan(metrics.size.width, 1)
    XCTAssertGreaterThan(metrics.size.height, metrics.lineHeight * 2)
  }

  func testMixedDirectionFallbackTextLayoutFitsAvailableWidth() {
    let value = "Invoice אבג 123 — العربية 🖋️\nSecond line"
    let contentWidth: CGFloat = 140
    let metrics = InkSignPdfTextRenderer.layout(text: value,
                                                fontSize: 18,
                                                isRTL: true,
                                                contentWidth: contentWidth)
    XCTAssertLessThanOrEqual(metrics.maximumLineWidth, contentWidth)
    XCTAssertGreaterThan(metrics.size.height, metrics.lineHeight)
  }
  private func sampleDrawing() -> PKDrawing {
    let points = [CGPoint(x: 80, y: 90), CGPoint(x: 110, y: 115)].enumerated().map { index, location in
      PKStrokePoint(location: location, timeOffset: Double(index) * 0.01,
        size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
    }
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
      path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity, mask: nil)])
  }

  func testAcceptChangesCancelsLiveInkAndKeepsPresentationAndModeSession() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let session = try view.setMode(mode: .ink, options: nil)
    let canvas = view.canvasView
    view.canvasViewDidBeginUsingTool(canvas)
    canvas.isInstallingDrawing = true
    canvas.drawing = sampleDrawing()
    canvas.isInstallingDrawing = false
    view.canvasViewDidEndUsingTool(canvas)
    view.canvasViewDrawingDidChange(canvas)
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let committed = page.history.content.drawing.dataRepresentation()
    let presented = view.viewerDocument
    let generation = view.documentCoordinator.generation
    view.canvasViewDidBeginUsingTool(canvas)
    canvas.isInstallingDrawing = true
    canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + sampleDrawing().strokes)
    canvas.isInstallingDrawing = false
    XCTAssertTrue(view.hasDrawingTransaction)
    let document = try attachedDocument(view)
    try awaitTestPromise(document.acceptChanges())
    XCTAssertFalse(view.hasDrawingTransaction)
    XCTAssertEqual(page.history.content.drawing.dataRepresentation(), committed)
    XCTAssertEqual(canvas.drawing.strokes.count, 1)
    XCTAssertTrue(view.viewerDocument === presented)
    XCTAssertEqual(view.documentCoordinator.generation, generation)
    XCTAssertFalse(view.documentCoordinator.isDirty)
    XCTAssertFalse(page.history.canUndo)
    XCTAssertFalse(page.history.canRedo)
    let handle = try awaitTestPromise(session.getPage(pageIndex: nil))
    XCTAssertEqual(try handle.getState().pageId, page.id.uuidString)
  }

  func testEndedDrawingStaysVisibleThroughPublicationAndRecordsOneUndo() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    _ = try view.setMode(mode: .ink, options: nil)
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let canvas = view.canvasView
    view.canvasViewDidBeginUsingTool(canvas)
    XCTAssertTrue(view.hasDrawingTransaction)
    canvas.isInstallingDrawing = true
    canvas.drawing = sampleDrawing()
    canvas.isInstallingDrawing = false
    view.canvasViewDidEndUsingTool(canvas)
    let visible = canvas.drawing.dataRepresentation()
    let observer = view.documentCore.observe { change in
      if case .page(let id) = change, id == page.id {
        XCTAssertTrue(view.hasDrawingTransaction)
        XCTAssertEqual(canvas.drawing.dataRepresentation(), visible)
      }
    }
    view.canvasViewDrawingDidChange(canvas)
    view.documentCore.removeObserver(observer)
    XCTAssertFalse(view.hasDrawingTransaction)
    XCTAssertEqual(canvas.drawing.dataRepresentation(), visible)
    XCTAssertEqual(page.history.content.drawing.strokes.count, 1)
    let context = InkSignPdfCorePageContext(generation: view.documentCoordinator.generation, pageID: page.id)
    try view.documentCore.undo(context)
    XCTAssertTrue(page.history.content.drawing.strokes.isEmpty)
    XCTAssertFalse(page.history.state.canUndo)
    try view.documentCore.redo(context)
    XCTAssertEqual(page.history.content.drawing.strokes.count, 1)

    view.canvasViewDidBeginUsingTool(canvas)
    view.cancelActiveStroke()
    canvas.isInstallingDrawing = true
    canvas.drawing = sampleDrawing()
    canvas.isInstallingDrawing = false
    view.canvasViewDrawingDidChange(canvas)
    assertDrawingGeometry(canvas.drawing,
      matches: page.history.content.drawing.transformed(using: try XCTUnwrap(view.pageToOverlayTransform)))
  }

  /// Cancellation restores visible stroke content, not an opaque archive encoding.
  private func assertDrawingGeometry(_ actual: PKDrawing, matches expected: PKDrawing,
                                     file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.strokes.count, expected.strokes.count, file: file, line: line)
    for (actualStroke, expectedStroke) in zip(actual.strokes, expected.strokes) {
      XCTAssertEqual(actualStroke.ink.inkType, expectedStroke.ink.inkType, file: file, line: line)
      XCTAssertEqual(actualStroke.ink.color, expectedStroke.ink.color, file: file, line: line)
      let actualPoints = Array(actualStroke.path.interpolatedPoints(by: .distance(1)))
      let expectedPoints = Array(expectedStroke.path.interpolatedPoints(by: .distance(1)))
      XCTAssertEqual(actualPoints.count, expectedPoints.count, file: file, line: line)
      for (actualPoint, expectedPoint) in zip(actualPoints, expectedPoints) {
        let actualPosition = actualPoint.location.applying(actualStroke.transform)
        let expectedPosition = expectedPoint.location.applying(expectedStroke.transform)
        XCTAssertEqual(actualPosition.x, expectedPosition.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actualPosition.y, expectedPosition.y, accuracy: 0.01, file: file, line: line)
        let actualScale = hypot(actualStroke.transform.a, actualStroke.transform.b)
        let expectedScale = hypot(expectedStroke.transform.a, expectedStroke.transform.b)
        XCTAssertEqual(actualPoint.size.width * actualScale, expectedPoint.size.width * expectedScale,
          accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actualPoint.opacity, expectedPoint.opacity, accuracy: 0.001, file: file, line: line)
      }
    }
  }

  func testSceneDeactivationCancelsLiveInputAndPreservesCommittedInk() throws {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
      throw XCTSkip("Requires a connected window scene")
    }
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    fixture.window.windowScene = scene
    let view = fixture.view
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let context = InkSignPdfCorePageContext(generation: view.documentCoordinator.generation, pageID: page.id)
    let committed = sampleDrawing()
    XCTAssertTrue(try view.documentCore.commitDrawing(committed,
      replacing: page.history.content.drawing, context: context))
    _ = try view.setMode(mode: .ink, options: nil)
    view.canvasViewDidBeginUsingTool(view.canvasView)
    let transform = try XCTUnwrap(view.pageToOverlayTransform)
    view.canvasView.isInstallingDrawing = true
    view.canvasView.drawing = PKDrawing(strokes: committed.strokes + sampleDrawing().strokes)
      .transformed(using: transform)
    view.canvasView.isInstallingDrawing = false
    NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
    XCTAssertTrue(view.sameDrawing(page.history.content.drawing, committed))
    assertDrawingGeometry(view.canvasView.drawing, matches: committed.transformed(using: transform))
  }

  func testPenWidthUsesDisplayPointsAndStaysFixedDuringInput() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    _ = try view.setMode(mode: .ink, options: nil)
    let canvas = view.canvasView
    canvas.minimumZoomScale = 0.5
    canvas.maximumZoomScale = 4
    for zoom in [CGFloat(1), 2] {
      canvas.zoomScale = zoom
      view.updateCanvasPen(canvas)
      let origin = canvas.convert(CGPoint.zero, to: fixture.window)
      let axis = canvas.convert(CGPoint(x: 1, y: 0), to: fixture.window)
      let scale = hypot(axis.x - origin.x, axis.y - origin.y) * zoom
      XCTAssertEqual(try XCTUnwrap(canvas.tool as? PKInkingTool).width * scale,
        CGFloat(view.currentPen.maxWidth), accuracy: 0.001)
    }
    view.canvasViewDidBeginUsingTool(canvas)
    let heldWidth = try XCTUnwrap(canvas.tool as? PKInkingTool).width
    canvas.zoomScale = 1
    view.updateCanvasPen(canvas)
    XCTAssertEqual(try XCTUnwrap(canvas.tool as? PKInkingTool).width, heldWidth)
    view.cancelActiveStroke()
  }

}
