import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class PlacementRuleDetectorTests: XCTestCase {
  func testScansLowerHorizontalRulesAndRowsOfFilledRectangles() throws {
    let linesURL = try makePDF { context in
      context.setLineWidth(1)
      for row in 0..<4 {
        let y = CGFloat(722 + row * 12)
        context.beginPath()
        context.move(to: CGPoint(x: 44, y: y))
        context.addLine(to: CGPoint(x: 540, y: y))
        context.strokePath()
      }
    }
    defer { try? FileManager.default.removeItem(at: linesURL) }

    let dotsURL = try makePDF { context in
      for row in 0..<5 {
        for column in 0..<34 {
          let rect = CGRect(x: 32 + CGFloat(column * 9),
                            y: 230 + CGFloat(row * 22),
                            width: 1.8,
                            height: 1.8)
          context.fill(rect)
        }
      }
    }
    defer { try? FileManager.default.removeItem(at: dotsURL) }

    let lineRules = try scan(linesURL)
    XCTAssertEqual(lineRules.count, 4)
    XCTAssertTrue(lineRules.allSatisfy { $0.maxX - $0.minX > 490 && $0.y > 700 })

    let dottedRows = try scan(dotsURL)
    XCTAssertEqual(dottedRows.count, 5)
    XCTAssertTrue(dottedRows.allSatisfy { $0.maxX - $0.minX > 290 })
  }

  func testScansAnUpperPageWritingRule() throws {
    let url = try makePDF { context in
      context.setLineWidth(1)
      context.beginPath()
      context.move(to: CGPoint(x: 44, y: 200))
      context.addLine(to: CGPoint(x: 540, y: 200))
      context.strokePath()
    }
    defer { try? FileManager.default.removeItem(at: url) }

    let rules = try scan(url)
    XCTAssertEqual(rules.count, 1)
    XCTAssertEqual(rules[0].y, 200, accuracy: 0.01)
  }

  func testKeyTextSearchFoldsAsciiOccurrencesInCanonicalBounds() throws {
    let url = try makePDF { context in
      NSAttributedString(string: "Name   NAME",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 120))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: 0))
    let mediaBox = page.bounds(for: .mediaBox)
    let lookup = InkSignPdfPageAnalysis.build(generation: 1,
                                              pageID: UUID(),
                                              pageIndex: 0,
                                              page: page,
                                              mediaBox: mediaBox).lookup(key: "name")
    XCTAssertTrue(lookup.hasLiteralMatch)
    let matches = lookup.matches
    XCTAssertEqual(matches.count, 2)
    XCTAssertLessThan(matches[0].sourceIndex, matches[1].sourceIndex)
    XCTAssertTrue(matches.allSatisfy {
      $0.bounds.minX >= 0 && $0.bounds.minY >= 0 &&
        $0.bounds.maxX <= mediaBox.width && $0.bounds.maxY <= mediaBox.height &&
        $0.lineHeight > 0
    })
  }

  func testKeyTextSearchRejectsALiteralSpanningVisualLines() throws {
    let url = try makePDF { _ in
      NSAttributedString(string: "First",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 100))
      NSAttributedString(string: "Second",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 140))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: 0))
    let key = try XCTUnwrap(page.string)

    let lookup = InkSignPdfPageAnalysis.build(generation: 1,
                                              pageID: UUID(),
                                              pageIndex: 0,
                                              page: page,
                                              mediaBox: page.bounds(for: .mediaBox)).lookup(key: key)
    XCTAssertTrue(lookup.hasLiteralMatch)
    let matches = lookup.matches
    XCTAssertTrue(matches.isEmpty)
  }

  func testPDFKitExtractedSpaceWithoutGeometryStillAllowsMultiwordKeyLookup() throws {
    let url = try makePDF { context in
      let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
      // Separate PDF text runs let PDFKit infer the space from their gap.
      NSAttributedString(string: "Full", attributes: attributes)
        .draw(at: CGPoint(x: 80, y: 120))
      NSAttributedString(string: "Name", attributes: attributes)
        .draw(at: CGPoint(x: 128, y: 120))
    }
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: 0))
    let source = try XCTUnwrap(page.string)
    let sourceString = source as NSString
    let match = sourceString.range(of: "Full Name")
    XCTAssertNotEqual(match.location, NSNotFound, "PDFKit extracted: \(source)")
    let spaceIndex = match.location + ("Full" as NSString).length

    let analysis = InkSignPdfPageAnalysis.build(generation: 1,
                                                pageID: UUID(),
                                                pageIndex: 0,
                                                page: page,
                                                mediaBox: page.bounds(for: .mediaBox))
    let lookup = analysis.lookup(key: "Full Name")
    XCTAssertTrue(lookup.hasLiteralMatch)
    XCTAssertEqual(lookup.matches.count, 1)
    XCTAssertGreaterThan(lookup.matches[0].lineHeight, 0)
    XCTAssertNotNil(lookup.matches[0].lineCenterY)
    let reorderedLookup = analysis.lookup(key: "Name Full")
    XCTAssertEqual(reorderedLookup.matches.count, 1)
    XCTAssertEqual(reorderedLookup.matches.first?.bounds, lookup.matches.first?.bounds)
    XCTAssertFalse(analysis.lookup(key: "Full Nam").hasLiteralMatch)

    // PDFKit may assign a rectangle to inferred whitespace. Remove only that
    // geometry to cover extracted spaces with no drawable character bounds.
    var characterBounds = analysis.characterBounds
    XCTAssertEqual(characterBounds.count, sourceString.length)
    characterBounds[spaceIndex] = nil
    var characterVisualRows = analysis.characterVisualRows
    characterVisualRows[spaceIndex] = -1
    let geometrySparseAnalysis = InkSignPdfPageAnalysis(
      generation: analysis.generation,
      pageID: analysis.pageID,
      pageIndex: analysis.pageIndex,
      pageSize: analysis.pageSize,
      sourceText: analysis.sourceText,
      characterBounds: characterBounds,
      characterVisualRows: characterVisualRows,
      visualRows: analysis.visualRows,
      rules: analysis.rules,
      estimatedMemoryBytes: analysis.estimatedMemoryBytes)
    let geometrySparseLookup = geometrySparseAnalysis.lookup(key: "Full Name")
    XCTAssertTrue(geometrySparseLookup.hasLiteralMatch)
    XCTAssertEqual(geometrySparseLookup.matches.count, 1)
    XCTAssertGreaterThan(geometrySparseLookup.matches[0].lineHeight, 0)
    XCTAssertNotNil(geometrySparseLookup.matches[0].lineCenterY)
  }

  func testMultiwordKeyDoesNotCombineDistantFieldsOnOneRow() throws {
    let url = try makePDF { _ in
      let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
      NSAttributedString(string: "Full", attributes: attributes).draw(at: CGPoint(x: 80, y: 120))
      NSAttributedString(string: "Name", attributes: attributes).draw(at: CGPoint(x: 300, y: 120))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: 0))
    let analysis = InkSignPdfPageAnalysis.build(generation: 1, pageID: UUID(), pageIndex: 0,
                                               page: page, mediaBox: page.bounds(for: .mediaBox))
    XCTAssertFalse(analysis.lookup(key: "Full").matches.isEmpty)
    XCTAssertFalse(analysis.lookup(key: "Name").matches.isEmpty)
    XCTAssertTrue(analysis.lookup(key: "Full Name").matches.isEmpty)
  }

  func testKeyRuleSelectionSkipsEarlierNameWithoutRuleBeforeApplyingOccurrence() {
    let matches = [
      InkSignPdfKeyTextMatch(bounds: CGRect(x: 10, y: 10, width: 10, height: 10),
                             sourceIndex: 0,
                             lineHeight: 10),
      InkSignPdfKeyTextMatch(bounds: CGRect(x: 10, y: 30, width: 10, height: 10),
                             sourceIndex: 8,
                             lineHeight: 10),
      InkSignPdfKeyTextMatch(bounds: CGRect(x: 10, y: 50, width: 10, height: 10),
                             sourceIndex: 16,
                             lineHeight: 10),
    ]
    let rules = [InkSignPdfPlacementRule(minX: 25, maxX: 100, y: 40),
                 InkSignPdfPlacementRule(minX: 25, maxX: 100, y: 60)]
    let pageSize = CGSize(width: 120, height: 120)

    let first = InkSignPdfKeyRuleSelector.select(matches: matches,
                                                  rules: rules,
                                                  occurrence: .first,
                                                  directionRtl: false,
                                                  pageSize: pageSize)
    XCTAssertEqual(first?.match.sourceIndex, 8)
    XCTAssertEqual(first?.rule, rules[0])
    let last = InkSignPdfKeyRuleSelector.select(matches: matches,
                                                rules: rules,
                                                occurrence: .last,
                                                directionRtl: false,
                                                pageSize: pageSize)
    XCTAssertEqual(last?.match.sourceIndex, 16)
    XCTAssertEqual(last?.rule, rules[1])
    let multiline = InkSignPdfKeyTextMatch(bounds: CGRect(x: 10, y: 10, width: 10, height: 20),
                                           sourceIndex: 0,
                                           lineHeight: 0)
    XCTAssertNil(InkSignPdfKeyRuleSelector.select(matches: [multiline],
                                                   rules: rules,
                                                   occurrence: .first,
                                                   directionRtl: false,
                                                   pageSize: pageSize))
  }

  func testPageAnalysisSkipsExtractedNameWithoutAdjacentRule() throws {
    let url = try makePDF { context in
      NSAttributedString(string: "Name",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 100))
      NSAttributedString(string: "Name",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 200))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: 0))
    let mediaBox = page.bounds(for: .mediaBox)
    let analysis = InkSignPdfPageAnalysis.build(generation: 1,
                                                pageID: UUID(),
                                                pageIndex: 0,
                                                page: page,
                                                mediaBox: mediaBox)
    let lookup = analysis.lookup(key: "Name")
    XCTAssertTrue(lookup.hasLiteralMatch)
    XCTAssertEqual(lookup.matches.count, 2)
    let laterMatch = try XCTUnwrap(lookup.matches.last)
    let rule = InkSignPdfPlacementRule(minX: laterMatch.bounds.maxX + 3,
                                       maxX: mediaBox.width - 8,
                                       y: laterMatch.bounds.midY)

    let placement = InkSignPdfKeyRuleSelector.select(matches: lookup.matches,
                                                      rules: [rule],
                                                      occurrence: .first,
                                                      directionRtl: false,
                                                      pageSize: mediaBox.size)
    XCTAssertEqual(placement?.match.sourceIndex, laterMatch.sourceIndex)
  }

  func testPageAnalysisCacheReusesKeysAndExpiresOnGenerationChange() throws {
    let firstURL = try makePDF { context in
      NSAttributedString(string: "Name Signature",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 120))
    }
    let replacementURL = try makePDF { context in
      NSAttributedString(string: "Owner Signature",
                         attributes: [.font: UIFont.systemFont(ofSize: 18)])
        .draw(at: CGPoint(x: 80, y: 120))
    }
    let coordinator = InkSignPdfDocumentCoordinator()
    let pageID = UUID()
    let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    defer {
      coordinator.dispose()
      coordinator.pdfQueue.sync {}
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: replacementURL)
    }

    let first = try XCTUnwrap(coordinator.pdfQueue.sync {
      coordinator.pageAnalysis(sourceURL: firstURL,
                               generation: 4,
                               pageIndex: 0,
                               pageID: pageID,
                               mediaBox: mediaBox)
    })
    XCTAssertTrue(first.rules.isEmpty)
    XCTAssertTrue(first.lookup(key: "Name").hasLiteralMatch)
    XCTAssertTrue(first.lookup(key: "Signature").hasLiteralMatch)
    let reused = try XCTUnwrap(coordinator.pdfQueue.sync {
      coordinator.pageAnalysis(sourceURL: firstURL,
                               generation: 4,
                               pageIndex: 0,
                               pageID: pageID,
                               mediaBox: mediaBox)
    })
    XCTAssertEqual(reused.sourceText, first.sourceText)
    XCTAssertEqual(coordinator.pdfQueue.sync { coordinator.pageAnalysisBuildCountForTesting }, 1)

    let replacement = try XCTUnwrap(coordinator.pdfQueue.sync {
      coordinator.pageAnalysis(sourceURL: replacementURL,
                               generation: 5,
                               pageIndex: 0,
                               pageID: pageID,
                               mediaBox: mediaBox)
    })
    XCTAssertEqual(replacement.generation, 5)
    XCTAssertTrue(replacement.lookup(key: "Owner").hasLiteralMatch)
    XCTAssertFalse(replacement.lookup(key: "Name").hasLiteralMatch)
    XCTAssertEqual(coordinator.pdfQueue.sync { coordinator.pageAnalysisBuildCountForTesting }, 2)
  }

  func testKeyUnderlineRuleLeavesTheLabelAndMarginOutsideTheTextFlow() {
    let match = InkSignPdfKeyTextMatch(bounds: CGRect(x: 40, y: 20, width: 20, height: 10),
                                       sourceIndex: 0,
                                       lineHeight: 10)
    let ltrRule = InkSignPdfPlacementRule(minX: 50, maxX: 100, y: 25)
    let rtlRule = InkSignPdfPlacementRule(minX: 0, maxX: 50, y: 25)
    let pageSize = CGSize(width: 120, height: 120)

    let ltr = InkSignPdfKeyRuleSelector.select(matches: [match],
                                                rules: [ltrRule],
                                                occurrence: .first,
                                                directionRtl: false,
                                                pageSize: pageSize)
    XCTAssertEqual(ltr?.contentMinX, 62)
    XCTAssertEqual(ltr?.contentMaxX, 100)

    let rtl = InkSignPdfKeyRuleSelector.select(matches: [match],
                                                rules: [rtlRule],
                                                occurrence: .first,
                                                directionRtl: true,
                                                pageSize: pageSize)
    XCTAssertEqual(rtl?.contentMinX, 0)
    XCTAssertEqual(rtl?.contentMaxX, 38)
  }

  func testTableBorderStrokesDoNotBecomeWritingRules() throws {
    let url = try makePDF { context in
      context.setLineWidth(1)
      for y in [CGFloat(650), 720] {
        context.beginPath()
        context.move(to: CGPoint(x: 44, y: y))
        context.addLine(to: CGPoint(x: 540, y: y))
        context.strokePath()
      }
      for x in [CGFloat(44), 540] {
        context.beginPath()
        context.move(to: CGPoint(x: x, y: 650))
        context.addLine(to: CGPoint(x: x, y: 720))
        context.strokePath()
      }
    }
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertTrue(try scan(url).isEmpty)
  }

  func testScansOptionalSuppliedSolidRulePDF() throws {
    guard let linesURL = fixtureURL(named: "RaDaLqz0kjfZbrgDjeEd") else {
      throw XCTSkip("Optional local PDF fixture is not present")
    }
    let lineRules = try scan(linesURL)
    let lineDocument = try XCTUnwrap(PDFDocument(url: linesURL))
    let linePage = try XCTUnwrap(lineDocument.page(at: 0))
    let lowerRules = lineRules.filter {
      $0.y >= linePage.bounds(for: .mediaBox).height * 0.68
    }
    XCTAssertEqual(lowerRules.count, 4, "The supplied form has four lower writing rules")
  }

  func testScansOptionalSuppliedDottedRulePDF() throws {
    guard let dotsURL = fixtureURL(named: "גיל אייזנברג 3206") else {
      throw XCTSkip("Optional local PDF fixture is not present")
    }
    let dottedRows = try scan(dotsURL)
    XCTAssertGreaterThanOrEqual(dottedRows.count, 5,
                                 "The supplied form's evenly spaced dot rows should be candidates")
  }

  private func fixtureURL(named name: String) -> URL? {
    let fileName = "\(name).pdf"
    let configuredDirectory = ProcessInfo.processInfo.environment["INKSIGN_PDF_TEST_FIXTURES"]
    let directory: URL
    if let configuredDirectory {
      directory = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
    } else {
      let testSource = URL(fileURLWithPath: #filePath)
      let repositoryRoot = testSource.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      directory = repositoryRoot.appendingPathComponent("diagnostics", isDirectory: true)
    }
    let url = directory.appendingPathComponent(fileName)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private func makePDF(draw: (CGContext) -> Void) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("placement-rules-\(UUID().uuidString).pdf")
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0,
                                                         width: 595, height: 842))
    try renderer.writePDF(to: url) { context in
      context.beginPage()
      draw(context.cgContext)
    }
    return url
  }

  private func scan(_ url: URL, pageIndex: Int = 0) throws -> [InkSignPdfPlacementRule] {
    let document = try XCTUnwrap(PDFDocument(url: url))
    let page = try XCTUnwrap(document.page(at: pageIndex))
    return InkSignPdfPlacementRuleDetector.scan(url: url,
                                                pageIndex: pageIndex,
                                                mediaBox: page.bounds(for: .mediaBox))
  }
}
