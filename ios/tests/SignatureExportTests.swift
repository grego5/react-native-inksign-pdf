import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class SignatureExportTests: XCTestCase, InkSignViewTestSupport {
  func testNativeExportPersistsVectorAnnotationsAndExpandedSignatureBounds() throws {
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
    let snapshot = ExportPageSnapshot(pageIndex: 0,
                                      pageID: UUID(),
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
    XCTAssertTrue((page.string ?? "").contains("Source page content"))

    let textAnnotations = page.annotations.filter {
      $0.type?.caseInsensitiveCompare("FreeText") == .orderedSame
    }
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
      XCTAssertEqual(InkSignPdfVectorAnnotation.flags(of: annotation), 708)
      XCTAssertGreaterThan(annotation.bounds.width, 0)
      XCTAssertGreaterThan(annotation.bounds.height, 0)
      persistedSignatureBounds = persistedSignatureBounds.union(annotation.bounds)
    }
    var canonicalToPDF = InkSignPdfTextRenderer.canonicalToPDFTransform(for: committedMediaBox)
    let pathBounds = try XCTUnwrap(signature.path.copy(using: &canonicalToPDF)).boundingBoxOfPath
    let expectedAnnotationBounds = pathBounds.insetBy(
      dx: -InkSignPdfNativeExporter.signatureAppearanceMargin,
      dy: -InkSignPdfNativeExporter.signatureAppearanceMargin)
    assertBounds(persistedSignatureBounds, equals: expectedAnnotationBounds)

    let pdfBytes = try Data(contentsOf: outputURL)
    XCTAssertFalse(String(decoding: pdfBytes, as: UTF8.self).contains("/Subtype /Image"),
                    "This vector source and its module annotations contain no raster fallback.")
    let pdfAttachment = XCTAttachment(data: pdfBytes, uniformTypeIdentifier: "com.adobe.pdf")
    pdfAttachment.name = "native-ios-annotation-export.pdf"
    pdfAttachment.lifetime = .keepAlways
    add(pdfAttachment)
    attach(page.thumbnail(of: CGSize(width: 792, height: 612), for: .mediaBox),
           named: "native-ios-annotation-export.png")
    attach(drawing.image(from: CGRect(origin: .zero, size: mediaBox.size), scale: 1),
           named: "pencilkit-signature-reference.png")
  }

  func testFinalizeSerializesCommittedDrawingAndReopensVectorAppearance() throws {
    let fixture = makeFixture(pageCount: 1, applyInitialViewport: false)
    defer {
      fixture.view.dispose()
      fixture.window.isHidden = true
    }

    let drawing = straightVariableWidthDrawing()
    let page = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage)
    let before = page.history.content
    XCTAssertTrue(page.history.record(type: .ink,
                                      before: before,
                                      after: before.replacingDrawing(drawing)))
    let result = try fixture.view.finalize()
    let finalized = expectation(description: "committed signature is exported")
    result.then { path in
      defer { finalized.fulfill() }
      do {
        let url = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first {
          $0.type?.caseInsensitiveCompare("Stamp") == .orderedSame
        })
        XCTAssertTrue(annotation.hasAppearanceStream)
        XCTAssertEqual(InkSignPdfVectorAnnotation.flags(of: annotation), 708)
        let expectedPath = try XCTUnwrap(
          InkSignPdfSignatureVectorPath.filledStrokes(in: drawing).first).path
        let pathBounds = expectedPath.boundingBoxOfPath
        let pdfBounds = CGRect(x: pathBounds.minX,
                               y: 400 - pathBounds.maxY,
                               width: pathBounds.width,
                               height: pathBounds.height)
        let expectedBounds = pdfBounds.insetBy(
          dx: -InkSignPdfNativeExporter.signatureAppearanceMargin,
          dy: -InkSignPdfNativeExporter.signatureAppearanceMargin)
        assertBounds(annotation.bounds, equals: expectedBounds)
        let pdfAttachment = XCTAttachment(data: try Data(contentsOf: url),
                                          uniformTypeIdentifier: "com.adobe.pdf")
        pdfAttachment.name = "finalized-signature-workflow.pdf"
        pdfAttachment.lifetime = .keepAlways
        add(pdfAttachment)
        attach(page.thumbnail(of: CGSize(width: 792, height: 612), for: .mediaBox),
               named: "finalized-signature-workflow.png")
      } catch {
        XCTFail("The finalized signature must reopen as a vector annotation: \(error)")
      }
    }
    result.catch { error in
      XCTFail("Finalize failed: \(error)")
      finalized.fulfill()
    }
    wait(for: [finalized], timeout: 30)
  }

  func testExporterRejectsUnsupportedInkInsteadOfOmittingIt() throws {
    let sourceURL = temporaryPDFURL("unsupported-signature-source")
    let outputURL = temporaryPDFURL("unsupported-signature-output")
    defer {
      try? FileManager.default.removeItem(at: sourceURL)
      try? FileManager.default.removeItem(at: outputURL)
    }
    try writeVectorSource(to: sourceURL, mediaBox: CGRect(x: 0, y: 0,
                                                           width: 612, height: 792))
    let source = try XCTUnwrap(PDFDocument(url: sourceURL))
    let page = try XCTUnwrap(source.page(at: 0))
    let point = PKStrokePoint(location: CGPoint(x: 100, y: 100),
                              timeOffset: 0,
                              size: CGSize(width: 12, height: 12),
                              opacity: 1,
                              force: 0.5,
                              azimuth: 0,
                              altitude: .pi / 2)
    let stroke = PKStroke(ink: PKInk(.marker, color: .black),
                          path: PKStrokePath(controlPoints: [point], creationDate: Date()),
                          transform: .identity,
                          mask: nil)
    let snapshot = ExportPageSnapshot(pageIndex: 0,
                                      pageID: UUID(),
                                      geometry: PageGeometry(mediaBox: page.bounds(for: .mediaBox),
                                                             rotation: page.rotation),
                                      drawingData: PKDrawing(strokes: [stroke]).dataRepresentation(),
                                      textAnnotations: [])

    XCTAssertThrowsError(try InkSignPdfNativeExporter.write(sourceURL: sourceURL,
                                                            pages: [snapshot],
                                                            outputURL: outputURL)) { error in
      guard case InkSignPdfNativeExporterError.unsupportedInk(let reason) = error else {
        XCTFail("Unsupported ink must fail as an explicit export error: \(error)")
        return
      }
      XCTAssertTrue(reason.contains("unsupportedInk"))
    }
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
    let path = PKStrokePath(controlPoints: points, creationDate: Date())
    let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue),
                          path: path,
                          transform: .identity,
                          mask: nil)
    return PKDrawing(strokes: [stroke])
  }

  private func straightVariableWidthDrawing() -> PKDrawing {
    let points = [
      PKStrokePoint(location: CGPoint(x: 50, y: 180), timeOffset: 0,
                    size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 100, y: 180), timeOffset: 0.1,
                    size: CGSize(width: 8, height: 8), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 150, y: 180), timeOffset: 0.2,
                    size: CGSize(width: 20, height: 20), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 200, y: 180), timeOffset: 0.3,
                    size: CGSize(width: 8, height: 8), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
      PKStrokePoint(location: CGPoint(x: 250, y: 180), timeOffset: 0.4,
                    size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5,
                    azimuth: 0, altitude: .pi / 2),
    ]
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                        path: PKStrokePath(controlPoints: points,
                                                           creationDate: Date()),
                                        transform: .identity,
                                        mask: nil)])
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
