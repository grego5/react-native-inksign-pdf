import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PencilKit
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

  func testNativeExportAddsLockedTextAndReadOnlyVectorAnnotationsToSourcePages() throws {
    let sourceURL = temporaryPDFURL("native-export-source")
    let outputURL = temporaryPDFURL("native-export-output")
    defer {
      try? FileManager.default.removeItem(at: sourceURL)
      try? FileManager.default.removeItem(at: outputURL)
    }

    let sourceMediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let mediaBox = CGRect(x: -20, y: 16, width: 612, height: 792)
    try writeVectorSource(to: sourceURL, mediaBox: sourceMediaBox)
    let sourceDocument = try XCTUnwrap(PDFDocument(url: sourceURL))
    let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
    sourcePage.setBounds(mediaBox, for: .mediaBox)
    let cropBox = CGRect(x: -8, y: 28, width: 580, height: 760)
    sourcePage.setBounds(cropBox, for: .cropBox)
    sourcePage.rotation = 90
    XCTAssertTrue(sourceDocument.write(to: sourceURL))

    let committedSource = try XCTUnwrap(PDFDocument(url: sourceURL))
    let committedPage = try XCTUnwrap(committedSource.page(at: 0))
    let committedMediaBox = committedPage.bounds(for: .mediaBox)
    let committedCropBox = committedPage.bounds(for: .cropBox)
    let drawing = variableWidthDrawing()
    let signature = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: drawing).first)
    XCTAssertGreaterThan(signature.path.boundingBoxOfPath.height, 8)
    let geometry = PageGeometry(mediaBox: committedMediaBox,
                                rotation: committedPage.rotation)
    let text = [
      InkSignPdfTextAnnotation(id: "latin", text: "CoreText Latin",
                               bounds: CGRect(x: 60, y: 70, width: 260, height: 32),
                               fontSize: 18),
      InkSignPdfTextAnnotation(id: "hebrew", text: "עברית",
                               bounds: CGRect(x: 60, y: 110, width: 260, height: 32),
                               fontSize: 18, isRTL: true),
      InkSignPdfTextAnnotation(id: "arabic", text: "العربية",
                               bounds: CGRect(x: 60, y: 150, width: 260, height: 32),
                               fontSize: 18, isRTL: true),
    ]
    let pageID = UUID()
    let snapshot = ExportPageSnapshot(pageIndex: 0,
                                      pageID: pageID,
                                      geometry: geometry,
                                      drawingData: drawing.dataRepresentation(),
                                      textAnnotations: text)
    do {
      try InkSignPdfNativeExporter.write(sourceURL: sourceURL,
                                         pages: [snapshot],
                                         outputURL: outputURL)
    } catch {
      if let pdfData = try? Data(contentsOf: outputURL) {
        let attachment = XCTAttachment(data: pdfData,
                                       uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "native-ios-signature-export-validation-failure.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      throw error
    }

    let reopened = try XCTUnwrap(PDFDocument(url: outputURL))
    XCTAssertEqual(reopened.pageCount, 1)
    let page = try XCTUnwrap(reopened.page(at: 0))
    assertBounds(page.bounds(for: .mediaBox), equals: committedMediaBox)
    assertBounds(page.bounds(for: .cropBox), equals: committedCropBox)
    XCTAssertEqual(page.rotation, 90)
    XCTAssertTrue((page.string ?? "").contains("Source page content"),
                  "The original page content remains in the exported PDF.")

    let textAnnotations = page.annotations.filter { $0.type?.caseInsensitiveCompare("FreeText") == .orderedSame }
    XCTAssertEqual(textAnnotations.count, text.count)
    var unmatchedTextAnnotations = textAnnotations
    for expected in text {
      let index = try XCTUnwrap(unmatchedTextAnnotations.firstIndex {
        $0.contents == expected.text
      })
      let annotation = unmatchedTextAnnotations.remove(at: index)
      XCTAssertEqual(annotation.contents, expected.text)
      XCTAssertTrue(annotation.hasAppearanceStream)
      XCTAssertTrue(annotation.shouldDisplay)
      XCTAssertTrue(annotation.shouldPrint)
      let flags = InkSignPdfVectorAnnotation.flags(of: annotation)
      XCTAssertEqual(flags & InkSignPdfVectorAnnotation.textFlags,
                     InkSignPdfVectorAnnotation.textFlags)
      XCTAssertEqual(flags & InkSignPdfVectorAnnotation.readOnlyFlag, 0)
    }
    XCTAssertTrue(unmatchedTextAnnotations.isEmpty)

    let signatureAnnotations = page.annotations.filter {
      $0.type?.caseInsensitiveCompare("Stamp") == .orderedSame
    }
    XCTAssertFalse(signatureAnnotations.isEmpty)
    var persistedSignatureBounds = CGRect.null
    for annotation in signatureAnnotations {
      XCTAssertTrue(annotation.hasAppearanceStream)
      XCTAssertTrue(annotation.shouldDisplay)
      XCTAssertTrue(annotation.shouldPrint)
      let flags = InkSignPdfVectorAnnotation.flags(of: annotation)
      XCTAssertEqual(flags & InkSignPdfVectorAnnotation.signatureFlags,
                     InkSignPdfVectorAnnotation.signatureFlags)
      XCTAssertGreaterThan(annotation.bounds.width, 0)
      XCTAssertGreaterThan(annotation.bounds.height, 0)
      persistedSignatureBounds = persistedSignatureBounds.union(annotation.bounds)
    }
    var canonicalToPDF = InkSignPdfTextRenderer.canonicalToPDFTransform(for: committedMediaBox)
    let expectedSignatureBounds = try XCTUnwrap(
      signature.path.copy(using: &canonicalToPDF)).boundingBoxOfPath
    assertBounds(persistedSignatureBounds, equals: expectedSignatureBounds)

    let pdfBytes = try Data(contentsOf: outputURL)
    XCTAssertFalse(String(decoding: pdfBytes, as: UTF8.self).contains("/Subtype /Image"),
                    "The synthetic vector source and module annotations do not use raster fallback.")
    let pdfAttachment = XCTAttachment(data: pdfBytes, uniformTypeIdentifier: "com.adobe.pdf")
    pdfAttachment.name = "native-ios-annotation-export.pdf"
    pdfAttachment.lifetime = .keepAlways
    add(pdfAttachment)
    attach(page.thumbnail(of: CGSize(width: 792, height: 612), for: .mediaBox),
           named: "native-ios-annotation-export.png")
    attach(drawing.image(from: CGRect(origin: .zero, size: mediaBox.size), scale: 1),
           named: "pencilkit-signature-reference.png")
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

  private func writeVectorSource(to url: URL, mediaBox: CGRect) throws {
    var bounds = mediaBox
    let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 24, y: 24, width: 564, height: 744))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 40, y: 620, width: 160, height: 72))
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
    ]
    let sourceLine = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Source page content", attributes: attributes))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 40, y: 580)
    CTLineDraw(sourceLine, context)
    context.endPDFPage()
    context.closePDF()
  }

  private func variableWidthDrawing() -> PKDrawing {
    let points = [
      PKStrokePoint(location: CGPoint(x: 80, y: 150), timeOffset: 0,
                    size: CGSize(width: 4, height: 4), opacity: 1, force: 0.2,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 160, y: 110), timeOffset: 0.1,
                    size: CGSize(width: 10, height: 10), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 240, y: 155), timeOffset: 0.2,
                    size: CGSize(width: 20, height: 20), opacity: 1, force: 0.9,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 320, y: 115), timeOffset: 0.3,
                    size: CGSize(width: 8, height: 8), opacity: 1, force: 0.4,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 390, y: 160), timeOffset: 0.4,
                    size: CGSize(width: 3, height: 3), opacity: 1, force: 0.1,
                    azimuth: 0, altitude: .pi / 2),
    ]
    let strokePath = PKStrokePath(controlPoints: points, creationDate: Date())
    let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue),
                          path: strokePath,
                          transform: .identity,
                          mask: nil)
    return PKDrawing(strokes: [stroke])
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
