import CoreGraphics
import Foundation
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class NativePDFBackendTests: XCTestCase {
  private enum ColorChannel {
    case red
    case green
    case blue
  }

  func testCrossDocumentInsertionPreservesOrderVisiblePagesAndGeometry() throws {
    let sourceURL = temporaryPDFURL("page-import-source")
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let source = PDFDocument()
    let first = try imagePage(size: CGSize(width: 300, height: 400), color: .red)
    first.setBounds(CGRect(x: -24, y: 18, width: 300, height: 400), for: .mediaBox)
    first.setBounds(CGRect(x: -12, y: 34, width: 276, height: 360), for: .cropBox)
    first.rotation = 90
    let second = try imagePage(size: CGSize(width: 450, height: 240), color: .green)
    second.rotation = 270
    source.insert(first, at: 0)
    source.insert(second, at: 1)
    XCTAssertTrue(source.write(to: sourceURL))

    let sourceBytes = try Data(contentsOf: sourceURL)
    let readableSource = try XCTUnwrap(PDFDocument(url: sourceURL))
    let redSourcePage = try XCTUnwrap(readableSource.page(at: 0))
    let greenSourcePage = try XCTUnwrap(readableSource.page(at: 1))
    let redMediaBox = redSourcePage.bounds(for: .mediaBox)
    let redCropBox = redSourcePage.bounds(for: .cropBox)
    let redRotation = redSourcePage.rotation
    let greenMediaBox = greenSourcePage.bounds(for: .mediaBox)
    let greenRotation = greenSourcePage.rotation
    let destination = PDFDocument()
    destination.insert(try imagePage(size: CGSize(width: 200, height: 200), color: .blue), at: 0)
    destination.insert(redSourcePage, at: 1)
    destination.insert(greenSourcePage, at: 2)
    let movedPage = try XCTUnwrap(destination.page(at: 2))
    destination.removePage(at: 2)
    destination.insert(movedPage, at: 0)

    XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    let outputURL = temporaryPDFURL("cross-document-import")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    XCTAssertTrue(destination.write(to: outputURL))

    let reopened = try XCTUnwrap(PDFDocument(url: outputURL))
    XCTAssertEqual(reopened.pageCount, 3)
    let greenPage = try XCTUnwrap(reopened.page(at: 0))
    let bluePage = try XCTUnwrap(reopened.page(at: 1))
    let redPage = try XCTUnwrap(reopened.page(at: 2))
    XCTAssertEqual(greenPage.rotation, greenRotation)
    XCTAssertEqual(redPage.rotation, redRotation)
    assertBounds(bluePage.bounds(for: .mediaBox),
                 equals: CGRect(x: 0, y: 0, width: 200, height: 200))
    assertBounds(greenPage.bounds(for: .mediaBox),
                 equals: greenMediaBox)
    assertBounds(redPage.bounds(for: .mediaBox), equals: redMediaBox)
    assertBounds(redPage.bounds(for: .cropBox), equals: redCropBox)
    assertDominantColor(try centerPixel(of: greenPage), channel: .green)
    assertDominantColor(try centerPixel(of: bluePage), channel: .blue)
    assertDominantColor(try centerPixel(of: redPage), channel: .red)
  }

  func testHebrewFixtureLoadsForVisualReview() throws {
    guard let fixtureURL = Bundle(for: Self.self)
      .url(forResource: "RaDaLqz0kjfZbrgDjeEd", withExtension: "pdf") else {
      throw XCTSkip("The local Hebrew visual-review PDF is not part of the package.")
    }
    let document = try XCTUnwrap(PDFDocument(url: fixtureURL))
    XCTAssertEqual(document.pageCount, 1)
    let page = try XCTUnwrap(document.page(at: 0))
    attach(page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox),
           named: "hebrew-fixture-visual-review.png")
  }

  private func imagePage(size: CGSize, color: UIColor) throws -> PDFPage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      renderer.cgContext.setFillColor(color.cgColor)
      renderer.cgContext.fill(CGRect(origin: .zero, size: size))
    }
    return try XCTUnwrap(PDFPage(image: image))
  }

  private func centerPixel(of page: PDFPage) throws -> UIColor {
    let image = page.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
    let cgImage = try XCTUnwrap(image.cgImage)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
      CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try XCTUnwrap(CGContext(data: nil,
                                          width: cgImage.width,
                                          height: cgImage.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: cgImage.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo))
    context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                     width: cgImage.width, height: cgImage.height))
    let data = try XCTUnwrap(context.data)
    let offset = (cgImage.height / 2) * cgImage.width * 4 + (cgImage.width / 2) * 4
    let components = (0..<3).map { Int(data.load(fromByteOffset: offset + $0, as: UInt8.self)) }
    return UIColor(red: CGFloat(components[0]) / 255,
                   green: CGFloat(components[1]) / 255,
                   blue: CGFloat(components[2]) / 255,
                   alpha: 1)
  }

  private func assertDominantColor(_ color: UIColor,
                                   channel: ColorChannel,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
    let components = color.cgColor.components ?? [0, 0, 0]
    let red = components[0]
    let green = components[1]
    let blue = components[2]
    switch channel {
    case .red:
      XCTAssertGreaterThan(red, green + 0.3, file: file, line: line)
      XCTAssertGreaterThan(red, blue + 0.3, file: file, line: line)
    case .green:
      XCTAssertGreaterThan(green, red + 0.3, file: file, line: line)
      XCTAssertGreaterThan(green, blue + 0.3, file: file, line: line)
    case .blue:
      XCTAssertGreaterThan(blue, red + 0.3, file: file, line: line)
      XCTAssertGreaterThan(blue, green + 0.3, file: file, line: line)
    }
  }

  private func temporaryPDFURL(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(label)-\(UUID().uuidString).pdf")
  }

  private func assertBounds(_ actual: CGRect, equals expected: CGRect,
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
  }

  private func attach(_ image: UIImage, named name: String) {
    guard let data = image.pngData() else { return }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
