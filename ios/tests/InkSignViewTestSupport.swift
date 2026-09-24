import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

protocol InkSignViewTestSupport {}

extension InkSignViewTestSupport where Self: XCTestCase {
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
  id: String,
  text: String,
  fontSize: CGFloat,
  pageSize: CGSize,
  isRTL: Bool = false
) -> InkSignPdfTextAnnotation {
  let size = InkSignPdfTextAnnotation.intrinsicSize(of: text,
                                                   fontSize: fontSize,
                                                   isRTL: isRTL,
                                                   maximumWidth: pageSize.width)
  let x = size.width >= pageSize.width
    ? (pageSize.width - size.width) / 2
    : min(max((pageSize.width - size.width) / 2, 0), pageSize.width - size.width)
  let y = size.height >= pageSize.height
    ? (pageSize.height - size.height) / 2
    : min(max((pageSize.height - size.height) / 2, 0), pageSize.height - size.height)
  return InkSignPdfTextAnnotation(id: id,
                                  text: text,
                                  bounds: CGRect(x: x, y: y,
                                                 width: size.width, height: size.height),
                                  fontSize: fontSize,
                                  isRTL: isRTL)
}
