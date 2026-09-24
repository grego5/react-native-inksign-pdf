import CoreGraphics
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewStabilizationTests: XCTestCase {
  private let mediaBox = CGRect(x: -12, y: 24, width: 300, height: 200)
  private let viewBounds = CGRect(x: 0, y: 0, width: 640, height: 480)

  func testCanonicalAndPDFRoundTripsForEveryRotation() throws {
    for rotation in [0, 90, 180, 270] {
      let geometry = PageGeometry(mediaBox: mediaBox, rotation: rotation)
      let viewport = try XCTUnwrap(PageViewportTransform(
        geometry: geometry,
        bounds: viewBounds,
        zoom: 1.35,
        focus: CGPoint(x: 150, y: 100),
        generation: 7))
      let points = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: mediaBox.width, y: 0),
        CGPoint(x: mediaBox.width, y: mediaBox.height),
        CGPoint(x: 0, y: mediaBox.height),
        CGPoint(x: mediaBox.width / 2, y: mediaBox.height / 2),
      ]

      for canonical in points {
        let view = viewport.viewPoint(fromCanonical: canonical)
        assertPoint(viewport.canonicalPoint(fromView: view), equals: canonical)

        let pdf = viewport.pdfPoint(fromCanonical: canonical)
        assertPoint(viewport.canonicalPoint(fromPDF: pdf), equals: canonical)
        assertPoint(viewport.viewPoint(fromPDF: pdf), equals: view)
        assertPoint(viewport.pdfPoint(fromView: view), equals: pdf)
        assertPoint(pdf.applying(viewport.pdfToView), equals: view)
      }
    }
  }

  func testFitViewportCentersRotatedPageWithNonZeroOrigin() throws {
    let geometry = PageGeometry(mediaBox: mediaBox, rotation: 90)
    let displaySize = PageViewportTransform.displaySize(for: geometry)
    let fitZoom = min(viewBounds.width / displaySize.width,
                      viewBounds.height / displaySize.height)
    let viewport = try XCTUnwrap(PageViewportTransform(
      geometry: geometry,
      bounds: viewBounds,
      zoom: fitZoom,
      focus: CGPoint(x: mediaBox.width / 2, y: mediaBox.height / 2),
      generation: 9))

    XCTAssertEqual(viewport.pageFrame.midX, viewBounds.midX, accuracy: 0.0001)
    XCTAssertEqual(viewport.pageFrame.midY, viewBounds.midY, accuracy: 0.0001)
    XCTAssertEqual(viewport.pageFrame.width, displaySize.width * fitZoom,
                   accuracy: 0.0001)
    XCTAssertEqual(viewport.pageFrame.height, displaySize.height * fitZoom,
                   accuracy: 0.0001)
  }

  func testOverlayAndPDFMappingsUseTheSameViewportSnapshot() throws {
    let geometry = PageGeometry(mediaBox: mediaBox, rotation: 270)
    let viewport = try XCTUnwrap(PageViewportTransform(
      geometry: geometry,
      bounds: viewBounds,
      zoom: 0.85,
      focus: CGPoint(x: 120, y: 80),
      generation: 11))
    let documentToOverlay = CGAffineTransform(translationX: 23, y: 31)
      .scaledBy(x: 1.1, y: 0.9)
    let canonicalToOverlay = documentToOverlay
      .concatenating(viewport.canonicalToView)
    let pdfToOverlay = documentToOverlay
      .concatenating(viewport.pdfToView)
    let canonical = CGPoint(x: 72, y: 141)
    let pdf = viewport.pdfPoint(fromCanonical: canonical)
    let overlayPoint = canonical.applying(canonicalToOverlay)

    assertPoint(pdf.applying(pdfToOverlay), equals: overlayPoint)
    assertPoint(overlayPoint.applying(canonicalToOverlay.inverted()),
                equals: canonical)
  }

  func testTileTransformMatchesDisplayMapping() throws {
    let geometry = PageGeometry(mediaBox: mediaBox, rotation: 180)
    let viewport = try XCTUnwrap(PageViewportTransform(
      geometry: geometry,
      bounds: viewBounds,
      zoom: 1.2,
      focus: CGPoint(x: 150, y: 100),
      generation: 13))
    let pdf = viewport.pdfPoint(fromCanonical: CGPoint(x: 40, y: 60))
    let display = pdf.applying(viewport.pdfToDisplay)
    let tileOrigin = CGPoint(x: 37, y: 29)
    let renderZoom: CGFloat = 2.125
    let density: CGFloat = 2
    let device = pdf.applying(viewport.pdfToDeviceTransform(
      canonicalTileOrigin: tileOrigin,
      renderZoom: renderZoom,
      density: density))
    let expected = CGPoint(x: (display.x - tileOrigin.x) * renderZoom * density,
                           y: (display.y - tileOrigin.y) * renderZoom * density)

    assertPoint(device, equals: expected)
  }

  func testTilePlannerQuantizesAndBoundsEveryAllocation() throws {
    let zooms: [CGFloat] = [0.1, 0.75, 1, 2, 16]
    for zoom in zooms {
      let plan = try XCTUnwrap(InkSignPdfTilePlan(
        pageSize: CGSize(width: 1200, height: 900),
        viewportZoom: zoom,
        density: 3))
      let expectedRenderZoom = min(16, max(0.125, ceil(zoom * 8) / 8))
      XCTAssertEqual(plan.renderZoom, expectedRenderZoom, accuracy: 0.0001)
      XCTAssertLessThanOrEqual(plan.renderZoom, 16)

      var sampledBytes = 0
      for row in 0..<min(plan.rows, 4) {
        for column in 0..<min(plan.columns, 4) {
          let tile = try XCTUnwrap(plan.tile(column: column, row: row))
          XCTAssertLessThanOrEqual(tile.pixelWidth, InkSignPdfTilePlan.pixelLimit)
          XCTAssertLessThanOrEqual(tile.pixelHeight, InkSignPdfTilePlan.pixelLimit)
          XCTAssertEqual(tile.byteCost, tile.pixelWidth * 4 * tile.pixelHeight)
          sampledBytes += tile.byteCost
        }
      }
      XCTAssertLessThanOrEqual(sampledBytes, InkSignPdfTilePlan.maxCacheBytes)
    }
  }

  func testTilePlannerRejectsInvalidDimensionsWithoutAllocation() {
    XCTAssertNil(InkSignPdfTilePlan(pageSize: .zero, viewportZoom: 1, density: 2))
    XCTAssertNil(InkSignPdfTilePlan(
      pageSize: CGSize(width: CGFloat.greatestFiniteMagnitude,
                       height: CGFloat.greatestFiniteMagnitude),
      viewportZoom: 16,
      density: 3))
    XCTAssertNil(InkSignPdfTilePlan(pageSize: CGSize(width: 100, height: 100),
                                   viewportZoom: .nan,
                                   density: 2))
  }

  func testTextLayoutUsesExplicitLinesAndTrailingEmptyLine() {
    let metrics = InkSignPdfTextRenderer.layout(text: "wide\n\n", fontSize: 16)

    XCTAssertEqual(metrics.lines, ["wide", "", ""])
    XCTAssertEqual(metrics.size.width, metrics.maximumLineWidth, accuracy: 0.0001)
    XCTAssertEqual(metrics.size.height, metrics.lineHeight * 3, accuracy: 0.0001)
    XCTAssertGreaterThan(metrics.size.width, 1)
    XCTAssertGreaterThan(metrics.size.height, metrics.lineHeight * 2)
  }

  private func assertPoint(
    _ actual: CGPoint?,
    equals expected: CGPoint,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let actual else {
      XCTFail("expected a point", file: file, line: line)
      return
    }
    assertPoint(actual, equals: expected, file: file, line: line)
  }

  private func assertPoint(
    _ actual: CGPoint,
    equals expected: CGPoint,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001, file: file, line: line)
  }
}
