import Foundation
import ImageIO
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class MutablePageImageEncoderTests: XCTestCase {
  func testNewPdfCanBeAssembledDirectlyFromPdfAndImageInputs() throws {
    let sourcePDF = try pdfData(width: 500, height: 400)
    let imageURL = try makeJPEG(orientation: 1)
    defer { try? FileManager.default.removeItem(at: imageURL) }
    let imageInput = try InkSignPdfMutablePageImageEncoder.encode(
      imageURL,
      geometry: PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0))
    let scratch = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    defer { InkSignPdfCacheArtifactPolicy.shared.deleteExact(scratch) }

    let sizes = try InkSignPdfPdfiumSession.assembleNewPDF(
      appendInputs: [["type": "pdf", "data": sourcePDF], imageInput],
      scratchURL: scratch)
    let document = try XCTUnwrap(PDFDocument(url: scratch))
    let session = try InkSignPdfPdfiumSession(data: Data(contentsOf: scratch),
                                             fallbackFontPath: nil,
                                             collectionIndex: 0)
    defer { session.close() }
    XCTAssertEqual(document.pageCount, 2)
    XCTAssertEqual(sizes.count, 2)
    var imagePageSize = CGSize.zero
    try session.pageSize(for: 1, into: &imagePageSize)
    XCTAssertEqual(imagePageSize.width, 612, accuracy: 0.5)
    XCTAssertEqual(imagePageSize.height, 792, accuracy: 0.5)
  }

  func testAssemblyKeepsMixedPdfAndImageSelectionOrder() throws {
    let baseData = try pdfData(width: 300, height: 400)
    let insertedPDF = try pdfData(width: 500, height: 400)
    let source = try makeJPEG(orientation: 1)
    defer { try? FileManager.default.removeItem(at: source) }
    let imageInput = try InkSignPdfMutablePageImageEncoder.encode(
      source,
      geometry: PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 300, height: 400), rotation: 0))
    let scratch = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    defer { InkSignPdfCacheArtifactPolicy.shared.deleteExact(scratch) }
    let session = try InkSignPdfPdfiumSession(data: baseData,
                                             fallbackFontPath: nil,
                                             collectionIndex: 0)
    defer { session.close() }

    let sizes = try session.assemble(
      data: baseData,
      operation: 0,
      pageIndex: 0,
      destinationIndex: 0,
      appendInputs: [
        ["type": "pdf", "data": insertedPDF],
        imageInput,
      ],
      scratchURL: scratch)
    let result = try XCTUnwrap(PDFDocument(url: scratch))
    XCTAssertEqual(result.pageCount, 3)
    XCTAssertEqual(sizes.count, 3)
    XCTAssertEqual(try XCTUnwrap(result.page(at: 0)).bounds(for: .mediaBox).width, 300, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(result.page(at: 1)).bounds(for: .mediaBox).width, 500, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(result.page(at: 2)).bounds(for: .mediaBox).width, 300, accuracy: 0.5)
  }

  func testConcurrentRenderAndAssemblySharePdfiumSerialization() throws {
    let baseData = try pdfData(width: 300, height: 400)
    let scratch = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    defer { InkSignPdfCacheArtifactPolicy.shared.deleteExact(scratch) }
    let session = try InkSignPdfPdfiumSession(data: baseData,
                                             fallbackFontPath: nil,
                                             collectionIndex: 0)
    defer { session.close() }
    let group = DispatchGroup()
    let resultLock = NSLock()
    var renderSucceeded = false
    var assembledPageCount = 0
    var operationError: Error?

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      let pixels = NSMutableData(length: 16 * 16 * 4)!
      do {
        try session.renderPage(0,
                               width: 16,
                               height: 16,
                               stride: 64,
                               pageToDevice: .identity,
                               clip: CGRect(x: 0, y: 0, width: 16, height: 16),
                               background: UInt32.max,
                               flags: 0,
                               pixels: pixels)
        resultLock.lock(); renderSucceeded = true; resultLock.unlock()
      } catch {
        resultLock.lock(); operationError = error; resultLock.unlock()
      }
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      do {
        let sizes = try session.assemble(data: baseData,
                                         operation: 0,
                                         pageIndex: 0,
                                         destinationIndex: 0,
                                         appendInputs: [["type": "pdf", "data": baseData]],
                                         scratchURL: scratch)
        resultLock.lock(); assembledPageCount = sizes.count; resultLock.unlock()
      } catch {
        resultLock.lock(); operationError = error; resultLock.unlock()
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    resultLock.lock()
    let rendered = renderSucceeded
    let pageCount = assembledPageCount
    let error = operationError
    resultLock.unlock()
    XCTAssertNil(error)
    XCTAssertTrue(rendered)
    XCTAssertEqual(pageCount, 2)
    XCTAssertEqual(PDFDocument(url: scratch)?.pageCount, 2)
  }

  func testCloseOverlappingRenderAndAssemblyLeavesNoOpenSession() throws {
    let baseData = try pdfData(width: 300, height: 400)
    let scratch = try InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    defer { InkSignPdfCacheArtifactPolicy.shared.deleteExact(scratch) }
    let session = try InkSignPdfPdfiumSession(data: baseData,
                                             fallbackFontPath: nil,
                                             collectionIndex: 0)
    let group = DispatchGroup()
    let resultLock = NSLock()
    var assembled = false
    var assemblyError: Error?
    var renderError: Error?

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      do {
        let sizes = try session.assemble(data: baseData,
                                         operation: 0,
                                         pageIndex: 0,
                                         destinationIndex: 0,
                                         appendInputs: [["type": "pdf", "data": baseData]],
                                         scratchURL: scratch)
        resultLock.lock(); assembled = sizes.count == 2; resultLock.unlock()
      } catch {
        resultLock.lock(); assemblyError = error; resultLock.unlock()
      }
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      let pixels = NSMutableData(length: 16 * 16 * 4)!
      do {
        try session.renderPage(0,
                               width: 16,
                               height: 16,
                               stride: 64,
                               pageToDevice: .identity,
                               clip: CGRect(x: 0, y: 0, width: 16, height: 16),
                               background: UInt32.max,
                               flags: 0,
                               pixels: pixels)
      } catch {
        resultLock.lock(); renderError = error; resultLock.unlock()
      }
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      session.close()
    }

    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    resultLock.lock()
    let didAssemble = assembled
    let candidateError = assemblyError
    let nativeRenderError = renderError
    resultLock.unlock()
    XCTAssertNil(candidateError)
    XCTAssertTrue(didAssemble)
    if let nativeRenderError {
      let error = nativeRenderError as NSError
      XCTAssertEqual(error.domain, InkSignPdfPdfiumErrorDomain)
      XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("closed"))
    }
    XCTAssertEqual(session.pageCount, 0)
  }

  func testEncoderContainsLandscapeImageOnWhitePage() throws {
    let source = try makeJPEG(orientation: 1)
    defer { try? FileManager.default.removeItem(at: source) }

    let encoded = try InkSignPdfMutablePageImageEncoder.encode(source, geometry: portraitGeometry)
    let jpeg = try XCTUnwrap(encoded["data"] as? Data)
    let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
    XCTAssertEqual(decoded.width, 200)
    XCTAssertEqual(decoded.height, 400)
    let pixels = try rgbaPixels(decoded)
    XCTAssertGreaterThan(pixels[10 * decoded.width * 4], 235, "top letterbox should be white")
    let center = (200 * decoded.width + 100) * 4
    XCTAssertGreaterThan(pixels[center + 1], 140, "the contained image should remain visible")
    XCTAssertEqual(encoded["a"] as? Double, 72)
    XCTAssertEqual(encoded["d"] as? Double, 144)
  }

  func testEncoderAppliesExifRotationBeforeFit() throws {
    let source = try makeJPEG(orientation: 6)
    defer { try? FileManager.default.removeItem(at: source) }

    let encoded = try InkSignPdfMutablePageImageEncoder.encode(source, geometry: portraitGeometry)
    let jpeg = try XCTUnwrap(encoded["data"] as? Data)
    let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
    let pixels = try rgbaPixels(decoded)
    let nearTop = (10 * decoded.width + 100) * 4
    XCTAssertGreaterThan(pixels[nearTop + 1], 140,
                         "EXIF-rotated content should fill the portrait page")
  }

  private var portraitGeometry: PageGeometry {
    PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: 72, height: 144), rotation: 0)
  }

  private func makeJPEG(orientation: UInt32) throws -> URL {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(data: nil,
                                          width: 200,
                                          height: 100,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.75, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = try XCTUnwrap(context.makeImage())
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfImage-\(UUID().uuidString).jpg")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            "public.jpeg" as CFString,
                                                            1,
                                                            nil) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(image, destination, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    return url
  }

  private func pdfData(width: CGFloat, height: CGFloat) throws -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let page = try XCTUnwrap(PDFPage(image: image))
    page.setBounds(CGRect(x: 0, y: 0, width: width, height: height), for: .mediaBox)
    let document = PDFDocument()
    document.insert(page, at: 0)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkSignPdfFixture-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    guard document.write(to: url) else { throw InkSignView.MutablePageError.assemblyFailed }
    return try Data(contentsOf: url)
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
}
