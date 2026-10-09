import QuartzCore
import UIKit

/// Owns one programmatic viewport transition. Each frame applies zoom and focus
/// together; completion belongs to the transition, not a layout-delay timer.
final class InkSignPdfViewportMotion: NSObject {
  private final class Transition {
    let from: ViewportTarget
    let to: ViewportTarget
    let started = CACurrentMediaTime()
    let update: (ViewportTarget) throws -> Void
    let completion: (Result<Void, Error>) -> Void
    var displayLink: CADisplayLink?

    init(from: ViewportTarget, to: ViewportTarget,
         update: @escaping (ViewportTarget) throws -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
      self.from = from
      self.to = to
      self.update = update
      self.completion = completion
    }
  }

  private var active: Transition?
  var isRunning: Bool { active != nil }

  func start(from: ViewportTarget, to: ViewportTarget,
             update: @escaping (ViewportTarget) throws -> Void,
             completion: @escaping (Result<Void, Error>) -> Void) {
    let previous = active
    let transition = Transition(from: from, to: to, update: update, completion: completion)
    active = transition
    previous?.displayLink?.invalidate()
    previous?.completion(.failure(InkSignView.ViewportError.cancelled))
    guard active === transition else { return }
    if from == to || UIAccessibility.isReduceMotionEnabled {
      apply(to, transition: transition, finished: true)
      return
    }
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    transition.displayLink = link
    link.add(to: .main, forMode: .common)
  }

  func cancel() {
    guard let transition = active else { return }
    finish(transition, result: .failure(InkSignView.ViewportError.cancelled))
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let transition = active, transition.displayLink === link else { return }
    let progress = min(max((link.timestamp - transition.started) / 0.25, 0), 1)
    let fraction = CGFloat(progress * progress * (3 - 2 * progress))
    let target = ViewportTarget(
      zoom: transition.from.zoom + (transition.to.zoom - transition.from.zoom) * fraction,
      focus: CGPoint(
        x: transition.from.focus.x + (transition.to.focus.x - transition.from.focus.x) * fraction,
        y: transition.from.focus.y + (transition.to.focus.y - transition.from.focus.y) * fraction))
    apply(target, transition: transition, finished: progress == 1)
  }

  private func apply(_ target: ViewportTarget, transition: Transition, finished: Bool) {
    do {
      try transition.update(target)
      if finished { finish(transition, result: .success(())) }
    } catch {
      finish(transition, result: .failure(error))
    }
  }

  private func finish(_ transition: Transition, result: Result<Void, Error>) {
    guard active === transition else { return }
    active = nil
    transition.displayLink?.invalidate()
    transition.displayLink = nil
    transition.completion(result)
  }
}
