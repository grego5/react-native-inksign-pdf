import CoreGraphics
import Foundation
import XCTest
@testable import ReactNativeInkSignPdf

final class SourceTextSelectionTests: XCTestCase {
  private func fixture(_ text: String, row: Int = 0, top: CGFloat = 0) -> InkSignPdfPageAnalysis {
    var bounds: [CGRect?] = []
    var rows: [Int] = []
    for (index, scalar) in text.unicodeScalars.enumerated() {
      for _ in String(scalar).utf16 {
        bounds.append(CGRect(x: CGFloat(index) * 10, y: top, width: 8, height: 10))
        rows.append(row)
      }
    }
    return InkSignPdfPageAnalysis(sourceText: text, characterBounds: bounds,
      characterVisualRows: rows, rules: [], labelCandidates: [])
  }

  func testBoxExpandsShrinksAndCopiesInSourceOrder() {
    let index = InkSignPdfSourceTextWords(analysis: fixture("AA B C"))
    var selection = InkSignPdfSourceTextSelection(index: index)
    selection.begin(index.words[1])
    selection.updateBox(to: CGPoint(x: 58, y: 10))
    XCTAssertEqual(selection.copyText(), "B C")
    selection.updateBox(to: CGPoint(x: 0, y: 0))
    XCTAssertEqual(selection.copyText(), "AA B")
    XCTAssertEqual(selection.highlightRectangles.first, CGRect(x: 0, y: 0, width: 18, height: 10))
    selection.finish()
    selection.updateBox(to: CGPoint(x: 58, y: 10))
    XCTAssertEqual(selection.copyText(), "AA B")
    selection.clear()
    XCTAssertNil(selection.copyText())
  }

  func testSegmentsCrossPhysicalWordsInBothDirections() {
    let index = InkSignPdfSourceTextWords(analysis: fixture("A B C"))
    XCTAssertEqual(index.crossed(from: CGPoint(x: -1, y: 5), to: CGPoint(x: 49, y: 5)).map(\.text), ["A", "B", "C"])
    XCTAssertEqual(index.crossed(from: CGPoint(x: 49, y: 5), to: CGPoint(x: -1, y: 5)).map(\.text), ["C", "B", "A"])
    XCTAssertTrue(index.crossed(from: CGPoint(x: 10, y: 15), to: CGPoint(x: 48, y: 15)).isEmpty)
    XCTAssertNil(index.hit(CGPoint(x: 15, y: 5), tolerance: 1))
    XCTAssertEqual(index.hit(CGPoint(x: 19, y: 5), tolerance: 2)?.text, "B")
  }

  func testUnicodeAndUTF16IdentityAreLossless() {
    let index = InkSignPdfSourceTextWords(analysis: fixture("😀 Hi!\u{A0}שלום مرحبا 😀e\u{301} Hi!"))
    XCTAssertEqual(index.words.map(\.text), ["😀", "Hi!", "שלום", "مرحبا", "😀e\u{301}", "Hi!"])
    XCTAssertEqual(index.words[1].id.start, 3)
    XCTAssertEqual(index.words[0].rectangles.count, 1)
    XCTAssertNotEqual(index.words[1].id, index.words.last!.id)
    let invisible = InkSignPdfPageAnalysis(sourceText: "a\u{200D}b", characterBounds: [
      CGRect(x: 0, y: 0, width: 8, height: 10), nil, CGRect(x: 10, y: 0, width: 8, height: 10)],
      characterVisualRows: [0, -1, 0], rules: [], labelCandidates: [])
    XCTAssertEqual(InkSignPdfSourceTextWords(analysis: invisible).words.first?.text, "a\u{200D}b")
    let empty = InkSignPdfPageAnalysis(sourceText: "A", characterBounds: [nil], characterVisualRows: [-1], rules: [], labelCandidates: [])
    XCTAssertTrue(InkSignPdfSourceTextWords(analysis: empty).words.isEmpty)
  }

  func testRowsSplitWithoutWhitespaceAndCopyUsesRowTransitions() {
    let analysis = InkSignPdfPageAnalysis(sourceText: "ABC", characterBounds: [
      CGRect(x: 0, y: 0, width: 8, height: 10), CGRect(x: 0, y: 30, width: 8, height: 10),
      CGRect(x: 20, y: 30, width: 8, height: 10)], characterVisualRows: [0, 1, 1], rules: [], labelCandidates: [])
    let prepared = InkSignPdfPreparedPage(analysis: analysis)
    let index = prepared.sourceWords
    XCTAssertTrue(index === prepared.sourceWords)
    XCTAssertEqual(index.words.map(\.text), ["A", "BC"])
    var selection = InkSignPdfSourceTextSelection(index: index)
    selection.begin(index.words[1])
    selection.updateBox(to: CGPoint(x: 0, y: 0))
    XCTAssertEqual(selection.copyText(), "A\nBC")
    XCTAssertEqual(index.crossed(from: CGPoint(x: -1, y: 5), to: CGPoint(x: 40, y: 5)).map(\.text), ["A"])
  }

  func testExactWhitespaceSet() {
    let whitespace: [UInt32] = [9, 10, 11, 12, 13, 32, 0x85, 0xA0, 0x1680] +
      Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    for scalar in whitespace {
      let index = InkSignPdfSourceTextWords(analysis: fixture("A" + String(UnicodeScalar(scalar)!) + "B"))
      XCTAssertEqual(index.words.map(\.text), ["A", "B"])
    }
    XCTAssertEqual(InkSignPdfSourceTextWords(analysis: fixture("A\u{200B}B")).words.first?.text, "A\u{200B}B")
  }
}
