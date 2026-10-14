import Foundation
import PDFKit
import PencilKit
import UIKit
import NitroModules

/// A command is ready when PDFKit has installed the active page and its overlay.
struct ViewportReadiness {
  let documentReady: Bool
  let viewInWindow: Bool
  let hasUsableBounds: Bool
  let activeOverlayAttached: Bool
  let fitScaleUsable: Bool

  func allowsCommand(fitToPage: Bool) -> Bool {
    documentReady && viewInWindow && hasUsableBounds && activeOverlayAttached &&
      (!fitToPage || fitScaleUsable)
  }
}

enum ViewportRequest {
  case preserve
  case fit
  case focus(CGPoint?, zoom: Double?)
}

struct ViewportTarget: Equatable {
  let zoom: CGFloat
  /// Current displayed page coordinates.
  let focus: CGPoint
}

enum InkSignPdfTextViewportGeometry {
  static func panDelta(outline: CGRect,
                       caret: CGRect,
                       visibleBounds: CGRect,
                       margin: CGFloat = 24) -> CGPoint {
    let safeBounds = visibleBounds.insetBy(dx: margin, dy: margin)
    return CGPoint(x: axisDelta(min: outline.minX,
                                max: outline.maxX,
                                caretCenter: caret.midX,
                                safeMin: safeBounds.minX,
                                safeMax: safeBounds.maxX),
                   y: axisDelta(min: outline.minY,
                                max: outline.maxY,
                                caretCenter: caret.midY,
                                safeMin: safeBounds.minY,
                                safeMax: safeBounds.maxY))
  }

  private static func axisDelta(min: CGFloat,
                                max: CGFloat,
                                caretCenter: CGFloat,
                                safeMin: CGFloat,
                                safeMax: CGFloat) -> CGFloat {
    if max - min > safeMax - safeMin { return (safeMin + safeMax) / 2 - caretCenter }
    if min < safeMin { return safeMin - min }
    if max > safeMax { return safeMax - max }
    return 0
  }
}

extension InkSignView {
  func requestUserTap() throws -> Promise<PageCoords> {
    try performOnMainSync { try interaction.requestCoordinates(modeSession: nil) }
  }

  @objc func handleCoordinateTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, !disposed,
          interaction.isPickingCoordinates,
          let document = viewerDocument else { return }
    let location = recognizer.location(in: documentView)
    guard let page = documentView.page(for: location, nearest: false),
          page === document.activePDFPage else { return }
    let point = documentView.convert(location, to: page)
      .applying(document.activePage.geometry.displayToPDFTransform.inverted())
    interaction.selectCoordinates(point, page: document.activePage, index: document.activePageIndex)
  }

  @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    interaction.viewport.handleDoubleTap(recognizer)
  }

  func configureCoordinateTapPriority(in view: UIView) {
    for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? [] {
      if tap !== coordinateTapGestureRecognizer { tap.require(toFail: coordinateTapGestureRecognizer) }
    }
    view.subviews.forEach { configureCoordinateTapPriority(in: $0) }
  }

  func applyPagerDirection() {
    performOnMain { [weak self] in self?.interaction.viewport.applyPagerDirectionNow() }
  }

  func programmaticPageSwitchCompletion() -> (Result<PageInfo, Error>) -> Void {
    { [weak self] result in
      switch result {
      case .success(let info):
        self?.emitPageState()
      case .failure(let error):
        self?.reportPageNavigationFailure(error)
      }
    }
  }

  func reportPageNavigationFailure(_ error: Error) {
    if let viewportError = error as? ViewportError,
       case .cancelled = viewportError { return }
    print("ReactNativeInkSignPdf page navigation failed: \(error.localizedDescription)")
  }

  @discardableResult
  func configureDoubleTapGestureRecognition() {
    documentView.gestureRecognizers?.forEach { recognizer in
      guard let tap = recognizer as? UITapGestureRecognizer,
            tap !== doubleTapGestureRecognizer,
            tap.numberOfTapsRequired >= 2 else { return }
      tap.require(toFail: doubleTapGestureRecognizer)
    }
  }

  static func parseViewport(_ options: ViewportOptions?) -> ViewportRequest {
    guard let options else { return .preserve }
    guard options.x != nil || options.y != nil || options.zoom != nil else { return .fit }
    let focus = options.x.flatMap { x in
      options.y.map { y in CGPoint(x: x, y: y) }
    }
    return .focus(focus, zoom: options.zoom)
  }

}
