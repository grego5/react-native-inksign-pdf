import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest

@testable import ReactNativeInkSignPdf

final class PdfFontOverlayCharacterizationTests: XCTestCase {
  func testCompatibilityRunMasksUniversalScalarsWithoutChangingText() throws {
    let run = InkSignPdfCompatibilityTextRun(
      text: "A שלום",
      bounds: CGRect(x: 10, y: 20, width: 80, height: 20),
      fontSize: 18,
      color: .black,
      fontStyle: .init(bold: false, italic: false),
      direction: .rightToLeft)
    let attributed = run.makeAttributedString()

    XCTAssertEqual(attributed.string, "A שלום")
    let asciiColor = try XCTUnwrap(
      attributed.attribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                           at: 0,
                           effectiveRange: nil) as? CGColor)
    let hebrewColor = try XCTUnwrap(
      attributed.attribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                           at: 2,
                           effectiveRange: nil) as? CGColor)
    XCTAssertEqual(asciiColor.alpha, 0, accuracy: 0.001)
    XCTAssertGreaterThan(hebrewColor.alpha, 0)
  }

  func testCompatibilityExtractionProducesCanonicalRunsForFixture() throws {
    let bundle = Bundle(for: PdfFontOverlayCharacterizationTests.self)
    let fixtureURL = try XCTUnwrap(
      bundle.url(forResource: "nonembedded-identity-text", withExtension: "pdf"))
    let document = try XCTUnwrap(PDFDocument(url: fixtureURL))
    let page = try XCTUnwrap(document.page(at: 0))
    let geometry = PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)

    let runs = InkSignPdfCompatibilityTextExtractor.extract(from: page, geometry: geometry)

    XCTAssertTrue(runs.contains { $0.text.contains("שלום") })
    XCTAssertTrue(runs.allSatisfy {
      $0.fontSize > 0 && $0.bounds.minX >= 0 && $0.bounds.minY >= 0 &&
        $0.bounds.maxX <= geometry.mediaBox.width && $0.bounds.maxY <= geometry.mediaBox.height
    })
  }

  func testPDFKitRecoversUnicodeAndFinitePlacementFromUnembeddedIdentityFont() throws {
    let bundle = Bundle(for: PdfFontOverlayCharacterizationTests.self)
    let fixtureURL = try XCTUnwrap(
      bundle.url(forResource: "nonembedded-identity-text", withExtension: "pdf"))
    let document = try XCTUnwrap(PDFDocument(url: fixtureURL))
    XCTAssertEqual(document.pageCount, 1)

    let page = try XCTUnwrap(document.page(at: 0))
    XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 240, height: 160))

    let pageString = try XCTUnwrap(page.string)
    let attributedString = try XCTUnwrap(page.attributedString)
    XCTAssertTrue(pageString.contains("2026: שלום"), pageString)
    XCTAssertTrue(pageString.contains("A-7"), pageString)
    XCTAssertTrue(attributedString.string.contains("2026: שלום"), attributedString.string)
    XCTAssertTrue(attributedString.string.contains("A-7"), attributedString.string)
    XCTAssertGreaterThan(page.numberOfCharacters, 0)

    let firstRun = (attributedString.string as NSString).range(of: "2026: שלום")
    XCTAssertNotEqual(firstRun.location, NSNotFound)
    for index in firstRun.location..<NSMaxRange(firstRun) {
      assertFiniteCharacterBounds(page.characterBounds(at: index))
    }

    let selection = try XCTUnwrap(page.selection(for: firstRun))
    XCTAssertFalse(selection.selectionsByLine().isEmpty)
  }

  private func assertFiniteCharacterBounds(_ bounds: CGRect,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
    XCTAssertTrue(bounds.origin.x.isFinite, file: file, line: line)
    XCTAssertTrue(bounds.origin.y.isFinite, file: file, line: line)
    XCTAssertTrue(bounds.width.isFinite, file: file, line: line)
    XCTAssertTrue(bounds.height.isFinite, file: file, line: line)
    XCTAssertGreaterThan(bounds.width, 0, file: file, line: line)
    XCTAssertGreaterThan(bounds.height, 0, file: file, line: line)
  }
}
