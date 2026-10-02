import CoreGraphics
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewStabilizationTests: XCTestCase {
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
}
