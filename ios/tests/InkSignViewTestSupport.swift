import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

protocol InkSignViewTestSupport {}

extension InkSignViewTestSupport where Self: XCTestCase {
  func awaitModeChange(_ promise: Promise<Void>) throws {
    let completed = expectation(description: "queued mode applies")
    var failure: Error?
    promise.then { _ in completed.fulfill() }
    promise.catch { failure = $0; completed.fulfill() }
    wait(for: [completed], timeout: 5)
    if let failure { throw failure }
  }

  func makeFixture(
    pageCount: Int = 2,
    activePageIndex: Int = 0,
    applyInitialViewport: Bool = true
  ) -> (view: InkSignView, window: UIWindow, pages: [UUID]) {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let size = CGSize(width: 300 + index * 100, height: 400)
      let image = UIGraphicsImageRenderer(size: size).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
      }
      let page = PDFPage(image: image)!
      page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
      document.insert(page, at: index)
    }

    let workingURL = try! InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    XCTAssertTrue(document.write(to: workingURL))
    let loaded = try! InkSignPdfDocumentCandidateLoader.load(url: workingURL)
    let states = loaded.pages
    let view = InkSignView()
    let state = InkSignPdfDocumentState(sourceURL: workingURL,
                                        workingURL: workingURL,
                                        document: loaded.document,
                                        pages: states)
    XCTAssertTrue(view.documentCoordinator.publish(state,
                                                    generation: view.documentCoordinator.generation))
    XCTAssertTrue(view.documentCoordinator.selectPage(at: activePageIndex))

    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    view.overlayProvider.install(document: loaded.document,
                                 generation: view.documentCoordinator.generation)
    view.documentView.document = loaded.document
    view.documentView.go(to: states[activePageIndex].page)
    view.documentView.layoutIfNeeded()
    if applyInitialViewport {
      XCTAssertTrue(view.applyViewport(target: ViewportTarget(
        zoom: view.documentView.scaleFactorForSizeToFit,
        focus: CGPoint(x: 150, y: 200))))
    }
    let canvas = view.overlayProvider.canvasView(for: states[activePageIndex].id)!
    view.overlayDidDisplay(canvas, for: states[activePageIndex].id)
    view.pageToOverlayTransform = .identity
    view.overlayTransformPage = states[activePageIndex].id
    return (view, window, states.map(\.id))
  }

  func drainMainQueue() {
    let drained = expectation(description: "queued navigation callbacks")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
  }
}

func textEditor(in overlay: InkSignPdfTextInteractionOverlay) -> UITextView? {
  overlay.subviews.compactMap { $0 as? UITextView }.first
}

func makeCenteredTextAnnotation(
  id: UInt64,
  text: String,
  fontSize: CGFloat,
  pageSize: CGSize,
  isRTL: Bool = false
) -> InkSignPdfTextAnnotation {
  let size = InkSignPdfTextAnnotation.intrinsicSize(of: text,
                                                   fontSize: fontSize,
                                                   isRTL: isRTL,
                                                   maximumWidth: pageSize.width)
  let origin = InkSignPdfTextBoxGeometry.clampedOrigin(
    for: size,
    preferred: CGPoint(x: (pageSize.width - size.width) / 2,
                       y: (pageSize.height - size.height) / 2),
    pageSize: pageSize)
  return InkSignPdfTextAnnotation(id: id,
                                  text: text,
                                  bounds: CGRect(origin: origin, size: size),
                                  fontSize: fontSize,
                                  isRTL: isRTL)
}

func appendTextAnnotationForTest(
  _ annotation: InkSignPdfTextAnnotation,
  in view: InkSignView,
  pageIndex: Int
) throws -> InkSignPdfTextAnnotation {
  let document = try XCTUnwrap(view.documentCoordinator.document)
  let state = try XCTUnwrap(document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil)
  let alignment: TextAlignment
  switch annotation.alignment {
  case .start: alignment = .start
  case .end: alignment = .end
  case .center: alignment = .center
  }
  let options = TextAnnotationOptions(
    fontSize: Double(annotation.fontSize),
    color: annotation.textColor,
    direction: annotation.isRTL ? .rtl : .ltr,
    maxLines: annotation.maxLines > 0 ? Double(annotation.maxLines) : nil,
    alignment: alignment,
    verticalAnchor: annotation.verticalAnchor == .bottom ? .bottom : .top)
  let flowBounds = annotation.flowBounds ?? annotation.bounds
  try view.textInteractionOverlay.addTextAnnotation(
    text: annotation.text,
    bounds: TextAnnotationBounds(x: Double(flowBounds.minX), y: Double(flowBounds.minY),
      width: Double(flowBounds.width), height: Double(flowBounds.height)),
    options: options,
    resolvedDirectionRtl: annotation.isRTL,
    capturedPage: (generation: view.documentCoordinator.generation,
      pageID: state.id, pageSize: state.geometry.displaySize,
      layoutRotation: state.geometry.rotation))
  return try XCTUnwrap(state.history.content.textAnnotations.last)
}

func insertTextForTest(
  _ text: String,
  bounds: TextAnnotationBounds,
  options: TextAnnotationOptions?,
  in view: InkSignView
) throws -> InkSignPdfTextAnnotation {
  let state = try XCTUnwrap(view.documentCoordinator.document?.activePage)
  try view.textInteractionOverlay.addTextAnnotation(
    text: text,
    bounds: bounds,
    options: options,
    capturedPage: (generation: view.documentCoordinator.generation,
      pageID: state.id, pageSize: state.geometry.displaySize,
      layoutRotation: state.geometry.rotation))
  return try XCTUnwrap(state.history.content.textAnnotations.last)
}
