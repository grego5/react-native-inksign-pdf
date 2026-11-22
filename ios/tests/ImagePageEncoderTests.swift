import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class ImagePageEncoderTests: XCTestCase {
  // Odd-width grayscale ramp; five rows use PNG filters 0...4 and three IDAT chunks.
  private let gray4 = "iVBORw0KGgoAAAANSUhEUgAAABEAAAAFBAAAAABDsbWqAAAAA0lEQVR4nGOqZ4K+AAAACElEQVRgVHZN71x99rHUlJQAAAAZSURBVP0HRkYlCGBkYoABZkZBCGBkgYsBAPRdBiSN/jLkAAAAAElFTkSuQmCC"
  private let transparentGray4 = "iVBORw0KGgoAAAANSUhEUgAAABEAAAAFBAAAAABDsbWqAAAAAnRSTlMAB+j3WJsAAAADSURBVHicY6pngr4AAAAISURBVGBUdk3vXH32sdSUlAAAABlJREFU/QdGRiUIYGRigAFmRkEIYGSBiwEA9F0GJI3+MuQAAAAASUVORK5CYII="

  func testGrayscalePngKeepsCompressedFourBitSamplesAndContainPlacement() throws {
    for (fixture, transparent) in [(gray4, false), (transparentGray4, true)] {
      let bytes = try XCTUnwrap(Data(base64Encoded: fixture))
      let source = temporaryJPEGURL().deletingPathExtension().appendingPathExtension("png")
      let output = temporaryPDFURL()
      defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: output)
      }
      try bytes.write(to: source)
      let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 170, height: 100), rotation: 0)
      let encoded = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry)
      XCTAssertEqual(encoded.data, bytes)
      XCTAssertEqual(encoded.placement, CGAffineTransform(a: 170, b: 0, c: 0, d: 50, tx: 0, ty: 25))
      try assemble(encoded, to: output)
      let pdf = try Data(contentsOf: output)
      let dictionary = String(decoding: pdf, as: UTF8.self)
      XCTAssertNotNil(dictionary.range(of: #"/BitsPerComponent\s+4\b"#, options: .regularExpression))
      XCTAssertTrue(dictionary.contains("/DeviceGray"))
      let compressed = try XCTUnwrap(Data(base64Encoded: "eJxjYFR2Te9cffb9B0ZGJQhgZGKAAWZGQQhgZIGLAQD0XQYk"))
      XCTAssertNotNil(pdf.range(of: compressed), "PDF must retain the original compressed samples")
      let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
      let thumbnail = page.thumbnail(of: CGSize(width: 170, height: 100), for: .mediaBox)
      let pixels = try rgbaPixels(XCTUnwrap(thumbnail.cgImage))
      XCTAssertGreaterThan(pixels[(10 * 170 + 85) * 4], 240, "Contain-fit margins stay white")
      for y in stride(from: 30, through: 70, by: 10) {
        XCTAssertLessThan(pixels[(y * 170 + 5) * 4], 20)
        XCTAssertGreaterThan(pixels[(y * 170 + 155) * 4], 235)
        XCTAssertLessThanOrEqual(abs(Int(pixels[(y * 170 + 75) * 4]) - (transparent ? 255 : 119)), 20)
      }
      XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
  }

  func testDpiPreservesSuitablePngAndQualityExplicitlyConvertsToJpeg() throws {
    let source = temporaryJPEGURL().deletingPathExtension().appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: source) }
    try XCTUnwrap(Data(base64Encoded: gray4)).write(to: source)
    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 170, height: 100), rotation: 0)
    let dpi = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry, targetDpi: 72)
    let quality = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry, jpegQuality: 0.8)
    XCTAssertEqual(dpi.data, try Data(contentsOf: source))
    XCTAssertEqual(dpi.placement, CGAffineTransform(a: 170, b: 0, c: 0, d: 50, tx: 0, ty: 25))
    XCTAssertEqual(Array(quality.data.prefix(2)), [255, 216])
    XCTAssertEqual(quality.placement, CGAffineTransform(scaleX: 170, y: 100))
  }

  func testDownsampledPngStaysFourBitGrayscaleAndExports() throws {
    let source = temporaryJPEGURL().deletingPathExtension().appendingPathExtension("png")
    let output = temporaryPDFURL()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: output)
    }
    try XCTUnwrap(Data(base64Encoded: gray4)).write(to: source)
    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 170, height: 100), rotation: 0)
    let encoded = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry, targetDpi: 3.6)
    XCTAssertEqual(encoded.data[24], 4)
    XCTAssertEqual(encoded.data[25], 0)
    let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    XCTAssertEqual(image.width, 9)
    XCTAssertEqual(image.height, 5)
    let pixels = try rgbaPixels(image)
    XCTAssertLessThan(pixels[(2 * 9) * 4], 40)
    XCTAssertGreaterThan(pixels[(2 * 9 + 8) * 4], 230)
    try assemble(encoded, to: output)
    XCTAssertTrue(String(decoding: try Data(contentsOf: output), as: UTF8.self).contains("/DeviceGray"))
  }

  func testPreservedJpegKeepsBytesAndDisplaysEveryExifOrientation() throws {
    let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                    [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
    let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
    let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<40 {
      for x in 0..<80 {
        let color = colors[(y < 20 ? 0 : 2) + (x < 40 ? 0 : 1)]
        let offset = (y * 80 + x) * 4
        for channel in 0..<3 { pixels[offset + channel] = color[channel] }
        pixels[offset + 3] = 255
      }
    }
    let image = try XCTUnwrap(context.makeImage())
    for orientation in 1...8 {
      let source = temporaryJPEGURL()
      let output = temporaryPDFURL()
      defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: output)
      }
      let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      let bytes = try Data(contentsOf: source)
      let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), rotation: 0)
      let encoded = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry, targetDpi: 200)
      XCTAssertEqual(encoded.data, bytes)
      try assemble(encoded, to: output)
      XCTAssertNotNil(try Data(contentsOf: output).range(of: bytes))
      let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
      let rendered = page.thumbnail(of: CGSize(width: 100, height: 100), for: .mediaBox)
      let actual = try rgbaPixels(XCTUnwrap(rendered.cgImage))
      for corner in 0..<4 {
        let x = orientation <= 4 ? (corner % 2 == 0 ? 25 : 75) : (corner % 2 == 0 ? 37 : 62)
        let y = orientation <= 4 ? (corner < 2 ? 37 : 62) : (corner < 2 ? 25 : 75)
        for channel in 0..<3 {
          XCTAssertLessThan(abs(Int(actual[(y * 100 + x) * 4 + channel]) - Int(colors[expected[orientation - 1][corner]][channel])),
            40, "EXIF \(orientation) corner \(corner)")
        }
      }
    }
  }

  func testMalformedPreservedPngDoesNotPublishPdf() throws {
    var bytes = try XCTUnwrap(Data(base64Encoded: gray4))
    bytes[bytes.count - 1] ^= 1 // IEND checksum.
    let output = temporaryPDFURL()
    defer { try? FileManager.default.removeItem(at: output) }
    XCTAssertThrowsError(try InkSignPdfPdfiumBackend.assemble(data: nil, operation: .create,
      inputs: [InkSignPdfPdfiumInput(imageData: bytes, pageSize: CGSize(width: 170, height: 100),
        rotation: 0, placement: CGAffineTransform(scaleX: 170, y: 50))],
      pageIndex: 0, destinationIndex: 0, outputURL: output))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testImageInputBecomesReopenablePdfPageWithRequestedGeometry() throws {
    let source = try makeJPEG(orientation: 1)
    defer { try? FileManager.default.removeItem(at: source) }

    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 72, height: 144),
                                rotation: 90)
    let encoded = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry)
    XCTAssertEqual(encoded.pageSize, geometry.mediaBox.size)
    XCTAssertEqual(encoded.rotation, 90)
    let url = temporaryPDFURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try assemble(encoded, to: url)

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
    let encoded = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry)
    let url = temporaryPDFURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try assemble(encoded, to: url)

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

    let defaultPage = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry)
    XCTAssertEqual(defaultPage.data, try Data(contentsOf: source))
    let suitableDpi = try InkSignPdfImagePageEncoder.encode(source, geometry: geometry, targetDpi: 400)
    XCTAssertEqual(suitableDpi.data, defaultPage.data)
    let lowerResolutionPage = try InkSignPdfImagePageEncoder.encode(
      source, geometry: geometry, targetDpi: 72)
    let lowerQualityPage = try InkSignPdfImagePageEncoder.encode(
      source, geometry: geometry, targetDpi: 72, jpegQuality: 0.1)
    let higherQualityPage = try InkSignPdfImagePageEncoder.encode(
      source, geometry: geometry, targetDpi: 72, jpegQuality: 1)

    XCTAssertLessThan(lowerResolutionPage.data.count,
                      defaultPage.data.count)
    XCTAssertLessThan(lowerQualityPage.data.count,
                      higherQualityPage.data.count)
  }

  func testExplicitDpiDoesNotUpscaleBeyondSmallSourceResolution() throws {
    let source = try makeDetailedJPEG(width: 20, height: 10)
    defer { try? FileManager.default.removeItem(at: source) }
    let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 144, height: 72),
                                rotation: 0)

    let requestedHighDpi = try InkSignPdfImagePageEncoder.encode(
      source, geometry: geometry, targetDpi: 300)
    let sourceResolution = try InkSignPdfImagePageEncoder.encode(
      source, geometry: geometry, targetDpi: 10)

    XCTAssertEqual(requestedHighDpi.data.count,
                   sourceResolution.data.count)
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
      throw MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, image,
                              [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw MutablePageError.unsupportedContent
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
      throw MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, image,
                              [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw MutablePageError.unsupportedContent
    }
    return url
  }

  private func assemble(_ encoded: InkSignPdfEncodedImage, to url: URL) throws {
    let pages = try InkSignPdfPdfiumBackend.assemble(data: nil, operation: .create,
      inputs: [encoded.nativeInput], pageIndex: 0, destinationIndex: 0, outputURL: url)
    XCTAssertEqual(pages.count, 1)
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
