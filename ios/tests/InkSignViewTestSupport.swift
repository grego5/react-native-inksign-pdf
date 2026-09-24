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
  ) -> (view: InkSignView, window: UIWindow, pages: [UUID],
        previewScheduler: TestPreviewScheduler,
        animationFactory: TestAnimationDriverFactory) {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 300 + index * 100, height: 400))
        .image { UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400)) }
      let page = PDFPage(image: image)!
      page.setBounds(CGRect(x: 0, y: 0, width: 300 + index * 100, height: 400), for: .mediaBox)
      document.insert(page, at: index)
    }
    let workingURL = try! InkSignPdfCacheArtifactPolicy.shared.allocateWorkingSource()
    XCTAssertTrue(document.write(to: workingURL))
    let loaded = try! InkSignPdfDocumentCandidateLoader.load(url: workingURL)
    let states = loaded.pages
    let previewScheduler = TestPreviewScheduler()
    let animationFactory = TestAnimationDriverFactory()
    let view = InkSignView(
      previewScheduler: previewScheduler,
      animationDriverFactory: animationFactory)
    let state = InkSignPdfDocumentState(
      sourceURL: workingURL,
      workingURL: workingURL,
      document: loaded.document,
      pages: states)
    XCTAssertTrue(view.documentCoordinator.publish(state, generation: view.documentCoordinator.generation))
    XCTAssertTrue(view.documentCoordinator.selectPage(at: activePageIndex))
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    window.rootViewController = controller
    controller.view.addSubview(view.view)
    view.view.frame = controller.view.bounds
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    view.documentView.installPage(
      index: activePageIndex,
      pageID: states[activePageIndex].id,
      geometry: states[activePageIndex].geometry,
      page: states[activePageIndex].page,
      document: loaded.document,
      generation: view.documentCoordinator.generation)
    view.documentView.layoutIfNeeded()
    if applyInitialViewport {
      XCTAssertTrue(view.documentView.applyViewport(
        zoom: view.documentView.scaleFactorForSizeToFit,
        focus: CGPoint(x: 150, y: 200),
        generation: view.documentCoordinator.generation))
    }
    view.canvasView.frame = view.documentView.bounds
    view.attachedOverlayPage = states[activePageIndex].id
    view.overlayTransformPage = states[activePageIndex].id
    view.pageToOverlayTransform = .identity
    view.pageTurnLifecycle.stableContextChanged()
    previewScheduler.completeAll()
    return (view, window, states.map(\.id), previewScheduler, animationFactory)
  }

  func drainMainQueue() {
    let drained = expectation(description: "queued navigation callbacks")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
  }

  func preparedPreview(
    _ direction: InkSignPdfEdgeNavigationPhysicalDirection,
    in view: InkSignView
  ) -> InkSignPdfPageTurnLifecycle.PreparedPreview? {
    guard case .some(.ready(let preview)) = view.pageTurnLifecycle.previewSlots[direction] else {
      return nil
    }
    return preview
  }

  func renderingRequest(
    _ direction: InkSignPdfEdgeNavigationPhysicalDirection,
    in view: InkSignView
  ) -> InkSignPdfPageTurnPreviewRequest? {
    guard case .some(.rendering(let rendering)) = view.pageTurnLifecycle.previewSlots[direction] else {
      return nil
    }
    return rendering.request
  }

  func isIdle(_ lifecycle: InkSignPdfPageTurnLifecycle) -> Bool {
    if case .idle = lifecycle.phase { return true }
    return false
  }

  func beginSubthresholdSettlement(in view: InkSignView) {
    XCTAssertTrue(beginPull(in: view))
    view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    view.pageTurnLifecycle.pullEnded()
  }

  @discardableResult
  func beginPull(in view: InkSignView) -> Bool {
    let location = CGPoint(x: view.documentView.bounds.midX,
                           y: view.documentView.bounds.midY)
    return view.prepareForEdgeNavigationTouch(at: location)
  }
}

func textEditor(in overlay: InkSignPdfTextInteractionOverlay) -> UITextView? {
  overlay.subviews.compactMap { $0 as? UITextView }.first
}

func makeCenteredTextAnnotation(
  id: String,
  text: String,
  fontSize: CGFloat,
  pageSize: CGSize
) -> InkSignPdfTextAnnotation {
  let size = InkSignPdfTextAnnotation.intrinsicSize(of: text, fontSize: fontSize)
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
                                  fontSize: fontSize)
}

final class TestPreviewScheduler: InkSignPdfPageTurnPreviewScheduler {
  final class Job {
    let request: InkSignPdfPageTurnPreviewRequest
    let completion: (UIImage?) -> Void

    init(request: InkSignPdfPageTurnPreviewRequest, completion: @escaping (UIImage?) -> Void) {
      self.request = request
      self.completion = completion
    }
  }

  private(set) var submittedRequests: [InkSignPdfPageTurnPreviewRequest] = []
  private var jobs: [Job] = []

  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void
  ) {
    submittedRequests.append(request)
    jobs.append(Job(request: request, completion: completion))
  }

  func completeNext(image: UIImage? = UIImage()) {
    precondition(!jobs.isEmpty, "expected a queued preview job")
    let job = jobs.removeFirst()
    job.completion(image)
  }

  func completeAll(image: UIImage? = UIImage()) {
    while !jobs.isEmpty {
      completeNext(image: image)
    }
  }

  func complete(request: InkSignPdfPageTurnPreviewRequest, image: UIImage?) {
    guard let index = jobs.firstIndex(where: { $0.request.key == request.key }) else {
      preconditionFailure("expected a queued preview request")
    }
    let job = jobs.remove(at: index)
    job.completion(image)
  }
}

final class TestAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory {
  weak var lastDriver: TestAnimationDriver?
  private(set) var callbackHandles: [TestAnimationCallbackHandle] = []

  var lastCallback: TestAnimationCallbackHandle? {
    callbackHandles.last
  }

  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver {
    let callback = TestAnimationCallbackHandle(update: update, finish: finish)
    callbackHandles.append(callback)
    let driver = TestAnimationDriver(callback: callback)
    lastDriver = driver
    return driver
  }
}

final class TestAnimationCallbackHandle {
  private let update: (CGFloat) -> Void
  private let finish: () -> Void

  init(update: @escaping (CGFloat) -> Void, finish: @escaping () -> Void) {
    self.update = update
    self.finish = finish
  }

  func advance(to progress: CGFloat) {
    update(progress)
  }

  func complete() {
    update(1)
    finish()
  }
}

final class TestAnimationDriver: InkSignPdfPageTurnAnimationDriver {
  private let callback: TestAnimationCallbackHandle

  init(callback: TestAnimationCallbackHandle) {
    self.callback = callback
  }

  func start() {}
  func stop() {}
  func advance(to progress: CGFloat) { callback.advance(to: progress) }
  func complete() { callback.complete() }
}
