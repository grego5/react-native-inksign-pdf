import CoreGraphics
import Foundation
import UIKit

protocol InkSignPdfPageTurnPreviewScheduler: AnyObject {
  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void)
}

final class InkSignPdfDispatchPreviewScheduler: InkSignPdfPageTurnPreviewScheduler {
  private let renderer: (InkSignPdfPageTurnPreviewRequest) -> UIImage?

  init(renderer: @escaping (InkSignPdfPageTurnPreviewRequest) -> UIImage? = {
    InkSignPdfPageTurnPreviewView.render(request: $0)
  }) {
    self.renderer = renderer
  }

  func schedule(
    _ request: InkSignPdfPageTurnPreviewRequest,
    completion: @escaping (UIImage?) -> Void
  ) {
    let renderer = self.renderer
    request.pdfQueue.async {
      let image = renderer(request)
      DispatchQueue.main.async {
        completion(image)
      }
    }
  }
}

protocol InkSignPdfPageTurnAnimationDriver: AnyObject {
  func start()
  func stop()
}

protocol InkSignPdfPageTurnAnimationDriverFactory: AnyObject {
  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver
}

final class ViewportAnimationDriverFactory: InkSignPdfPageTurnAnimationDriverFactory {
  func make(
    duration: CFTimeInterval,
    update: @escaping (CGFloat) -> Void,
    finish: @escaping () -> Void
  ) -> InkSignPdfPageTurnAnimationDriver {
    ViewportAnimationDriver(duration: duration, update: update, finish: finish)
  }
}
