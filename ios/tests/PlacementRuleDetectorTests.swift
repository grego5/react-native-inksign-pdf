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
