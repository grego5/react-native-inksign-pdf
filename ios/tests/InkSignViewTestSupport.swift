import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

protocol InkSignViewTestSupport {}

extension InkSignViewTestSupport where Self: XCTestCase {
  func attachedDocument(_ view: InkSignView) throws -> HybridInkSignDocument {
    try XCTUnwrap(view.document as? HybridInkSignDocument)
  }

  func documentPage(_ view: InkSignView, at pageIndex: Int? = nil) throws -> any HybridDocumentPageSpec {
    let owner = try attachedDocument(view)
    let index = pageIndex ?? view.viewerDocument?.activePageIndex ?? 0
    return try awaitTestPromise(owner.getPage(index: .first(Double(index))))
  }

  func awaitTestPromise<Value>(_ promise: Promise<Value>) throws -> Value {
    let completed = expectation(description: "native document operation settles")
    var value: Value?
    var failure: Error?
    promise.then { value = $0; completed.fulfill() }
      .catch { failure = $0; completed.fulfill() }
    wait(for: [completed], timeout: 30)
    if let failure { throw failure }
    return try XCTUnwrap(value)
  }

  func awaitViewerPageReady(_ view: InkSignView, pageID: UUID? = nil,
                            timeout: TimeInterval = 30) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let state = view.viewerDocument,
         pageID == nil || state.activePage.id == pageID,
         view.documentView.currentPage === state.activePDFPage,
         view.overlayProvider.isDisplaying(state.activePDFPage),
         view.attachedOverlayPage == state.activePage.id,
         view.overlayTransformPage == state.activePage.id,
         view.pageToOverlayTransform != nil,
         view.interaction.presentation == nil {
        return
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    XCTFail("The active page presentation did not become ready")
  }

  func holdCurrentStructuralPresentation(_ view: InkSignView) throws {
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let request = view.interaction.beginPresentation(page: page,
      structural: true, completion: nil)
    view.attachedOverlayPage = nil
    view.invalidateOverlayTransformCache()
    XCTAssertTrue(view.interaction.presentation === request)
  }

  func completeCurrentPagePresentation(_ view: InkSignView) throws {
    let pageID = try XCTUnwrap(view.viewerDocument?.activePage.id)
    let canvas = try XCTUnwrap(view.overlayProvider.canvasView(for: pageID))
    view.overlayDidDisplay(canvas, for: pageID)
    view.finishPagePresentationIfReady()
  }

  @discardableResult
  func attachDocument(from source: URL, to view: InkSignView) throws -> PageInfo {
    let core = InkSignDocumentCore(artifactPolicy: .shared, recordHistory: true)
    let loaded = expectation(description: "document opens before attachment")
    var failure: Error?
    core.open(sourceURL: source).then { _ in loaded.fulfill() }
      .catch { failure = $0; loaded.fulfill() }
    wait(for: [loaded], timeout: 120)
    if let failure { throw failure }
    let presented = expectation(description: "attached document presentation")
    var info: PageInfo?
    let previous = view.onPageChange
    view.onPageChange = { event in
      previous?(event)
      guard info == nil else { return }
      info = try? view.toPublicPageInfo(view.currentPageInfo())
      presented.fulfill()
    }
    defer { view.onPageChange = previous }
    view.document = HybridInkSignDocument(core: core)
    wait(for: [presented], timeout: 120)
    return try XCTUnwrap(info)
  }
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
    defer { try? FileManager.default.removeItem(at: workingURL) }
    let view = InkSignView()

    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    _ = try! attachDocument(from: workingURL, to: view)
    let states = view.documentCoordinator.document!.pages
    let requestedPage = view.viewerDocument!.pdfPage(for: states[activePageIndex].id)!
    view.documentView.go(to: requestedPage)
    view.documentView.layoutIfNeeded()
    XCTAssertTrue(view.viewerDocument!.selectPage(at: activePageIndex))
    if applyInitialViewport {
      XCTAssertTrue(view.interaction.viewport.applyViewport(target: ViewportTarget(
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
  let page = try pageForTest(view, at: pageIndex)
  let alignment: TextAlignment
  switch annotation.alignment {
  case .start: alignment = .start
  case .end: alignment = .end
  case .center: alignment = .center
  }
  let options = TextAnnotationOptions(untracked: nil, font: nil,
    fontSize: Double(annotation.fontSize),
    color: annotation.textColor,
    direction: annotation.isRTL ? .rtl : .ltr,
    maxLines: annotation.maxLines > 0 ? Double(annotation.maxLines) : nil,
    alignment: alignment,
    verticalAnchor: annotation.verticalAnchor == .bottom ? .bottom : .top)
  let flowBounds = annotation.flowBounds ?? annotation.bounds
  let bounds = TextAnnotationBounds(x: Double(flowBounds.minX), y: Double(flowBounds.minY),
    width: Double(flowBounds.width), height: Double(flowBounds.height))
  let id = try page.createInputArea(options: CreateInputAreaOptions(bounds: bounds,
    font: nil, fontSize: options.fontSize, color: options.color, direction: options.direction,
    maxLines: options.maxLines, alignment: options.alignment, verticalAnchor: options.verticalAnchor))
  try page.setTextValue(id: id, text: annotation.text, options: options)
  return try committedTextForTest(id: id, page: page, in: view)
}

func insertTextForTest(
  _ text: String,
  bounds: TextAnnotationBounds,
  options: TextAnnotationOptions?,
  in view: InkSignView
) throws -> InkSignPdfTextAnnotation {
  let pageIndex = view.viewerDocument?.activePageIndex ?? 0
  let page = try pageForTest(view, at: pageIndex)
  let id = try page.createInputArea(options: CreateInputAreaOptions(bounds: bounds,
    font: options?.font, fontSize: options?.fontSize, color: options?.color,
    direction: options?.direction, maxLines: options?.maxLines,
    alignment: options?.alignment, verticalAnchor: options?.verticalAnchor))
  try page.setTextValue(id: id, text: text, options: options)
  return try committedTextForTest(id: id, page: page, in: view)
}

private func pageForTest(_ view: InkSignView, at pageIndex: Int) throws -> any HybridDocumentPageSpec {
  let owner = try XCTUnwrap(view.document as? HybridInkSignDocument)
  let completed = XCTestExpectation(description: "test page handle is acquired")
  var page: (any HybridDocumentPageSpec)?
  var failure: Error?
  try owner.getPage(index: .first(Double(pageIndex))).then { value in
    page = value
    completed.fulfill()
  }.catch { error in
    failure = error
    completed.fulfill()
  }
  guard XCTWaiter.wait(for: [completed], timeout: 30) == .completed else {
    throw NSError(domain: "InkSignPdfTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "test page handle did not settle"])
  }
  if let failure { throw failure }
  return try XCTUnwrap(page)
}

private func committedTextForTest(
  id: Double,
  page: any HybridDocumentPageSpec,
  in view: InkSignView
) throws -> InkSignPdfTextAnnotation {
  let pageID = try XCTUnwrap(UUID(uuidString: page.getState().pageId))
  let state = try XCTUnwrap(view.viewerDocument?.pages.first { $0.id == pageID })
  return try XCTUnwrap(state.history.content.textAnnotations.first { $0.id == UInt64(id) })
}
