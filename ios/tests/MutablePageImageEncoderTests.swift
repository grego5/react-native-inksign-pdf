import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class MutablePageImageEncoderTests: XCTestCase {
  func testImageInputBecomesReopenablePdfPageWithRequestedGeometry() throws {
    let source = try makeJPEG(orientation: 1)
    defer { try? FileManager.default.removeItem(at: source) }

    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 72, height: 144),
                                rotation: 90)
    let page = try InkSignPdfMutablePageImageEncoder.encode(source, geometry: geometry)
    assertRect(page.bounds(for: .mediaBox), equals: geometry.mediaBox)
    XCTAssertEqual(page.rotation, 90)

    let candidate = PDFDocument()
    candidate.insert(page, at: 0)
    let url = temporaryPDFURL()
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(candidate.write(to: url))

    let reopened = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertEqual(reopened.pageCount, 1)
    let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
    assertRect(reopenedPage.bounds(for: .mediaBox), equals: geometry.mediaBox)
    XCTAssertEqual(reopenedPage.rotation, 90)
    XCTAssertGreaterThan(reopenedPage.thumbnail(of: CGSize(width: 144, height: 72),
                                                for: .mediaBox).size.width, 0)
  }

  func testEncoderAppliesExifOrientationBeforeContainFit() throws {
    let source = try makeJPEG(orientation: 6)
    defer { try? FileManager.default.removeItem(at: source) }

    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 72, height: 144),
                                rotation: 0)
    let page = try InkSignPdfMutablePageImageEncoder.encode(source, geometry: geometry)
    let document = PDFDocument()
    document.insert(page, at: 0)
    let url = temporaryPDFURL()
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(document.write(to: url))

    let reopenedPage = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
    let thumbnail = reopenedPage.thumbnail(of: CGSize(width: 200, height: 400),
                                          for: .mediaBox)
    XCTAssertEqual(thumbnail.size.width, 200, accuracy: 1)
    XCTAssertEqual(thumbnail.size.height, 400, accuracy: 1)
    let pixels = try rgbaPixels(try XCTUnwrap(thumbnail.cgImage))
    let top = (10 * 200 + 100) * 4
    XCTAssertGreaterThan(pixels[top + 1], 140,
                         "EXIF-oriented image content should cover the portrait page")
  }

  func testTargetDpiControlsRasterResolutionAndQualityControlsJpegEncoding() throws {
    let source = try makeDetailedJPEG(width: 800, height: 400)
    defer { try? FileManager.default.removeItem(at: source) }
    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 144, height: 72),
                                rotation: 0)

    let defaultPage = try InkSignPdfMutablePageImageEncoder.encode(source, geometry: geometry)
    let lowerResolutionPage = try InkSignPdfMutablePageImageEncoder.encode(
      source, geometry: geometry, targetDpi: 72)
    let lowerQualityPage = try InkSignPdfMutablePageImageEncoder.encode(
      source, geometry: geometry, targetDpi: 72, jpegQuality: 0.1)
    let higherQualityPage = try InkSignPdfMutablePageImageEncoder.encode(
      source, geometry: geometry, targetDpi: 72, jpegQuality: 1)

    XCTAssertLessThan(try serializedSize(of: lowerResolutionPage),
                      try serializedSize(of: defaultPage))
    XCTAssertLessThan(try serializedSize(of: lowerQualityPage),
                      try serializedSize(of: higherQualityPage))
  }

  func testExplicitDpiDoesNotUpscaleBeyondSmallSourceResolution() throws {
    let source = try makeDetailedJPEG(width: 20, height: 10)
    defer { try? FileManager.default.removeItem(at: source) }
    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 144, height: 72),
                                rotation: 0)

    let requestedHighDpi = try InkSignPdfMutablePageImageEncoder.encode(
      source, geometry: geometry, targetDpi: 300)
    let sourceResolution = try InkSignPdfMutablePageImageEncoder.encode(
      source, geometry: geometry, targetDpi: 10)

    XCTAssertEqual(try serializedSize(of: requestedHighDpi),
                   try serializedSize(of: sourceResolution))
  }

  private func makeJPEG(orientation: UInt32) throws -> URL {
    let context = try XCTUnwrap(CGContext(data: nil,
                                          width: 200,
                                          height: 100,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.75, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = try XCTUnwrap(context.makeImage())
    let url = temporaryJPEGURL()
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            "public.jpeg" as CFString,
                                                            1,
                                                            nil) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, image,
                              [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    return url
  }

  private func makeDetailedJPEG(width: Int, height: Int) throws -> URL {
    let context = try XCTUnwrap(CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width {
        let value = UInt8((x * 17 + y * 31 + x * y) % 256)
        let offset = (y * width + x) * 4
        pixels[offset] = value
        pixels[offset + 1] = value
        pixels[offset + 2] = value
        pixels[offset + 3] = 255
      }
    }
    let image = try XCTUnwrap(context.makeImage())
    let url = temporaryJPEGURL()
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            "public.jpeg" as CFString,
                                                            1,
                                                            nil) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, image,
                              [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    return url
  }

  private func serializedSize(of page: PDFPage) throws -> Int {
    let document = PDFDocument()
    document.insert(page, at: 0)
    return try XCTUnwrap(document.dataRepresentation()).count
  }

  private func temporaryPDFURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfImage-\(UUID().uuidString).pdf")
  }

  private func temporaryJPEGURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfImage-\(UUID().uuidString).jpg")
  }

  private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let data = NSMutableData(length: image.width * image.height * 4)!
    let context = try XCTUnwrap(CGContext(data: data.mutableBytes,
                                          width: image.width,
                                          height: image.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
  }

  private func assertRect(_ actual: CGRect,
                         equals expected: CGRect,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
  }
}
