import PDFKit
import UIKit

/// Hands all PDF presentation gestures to PDFKit in view mode and to the page
/// overlay in edit mode. The edit-mode walk follows PDFView's live child tree,
/// so it does not depend on private view or recognizer names.
final class PDFViewInteractionOwnership {
  private final class ViewState {
    weak var view: UIView?
    let isUserInteractionEnabled: Bool

    init(_ view: UIView) {
      self.view = view
      isUserInteractionEnabled = view.isUserInteractionEnabled
    }
  }

  private final class GestureState {
    weak var recognizer: UIGestureRecognizer?
    let isEnabled: Bool

    init(_ recognizer: UIGestureRecognizer) {
      self.recognizer = recognizer
      isEnabled = recognizer.isEnabled
    }
  }

  private var viewStates: [ObjectIdentifier: ViewState] = [:]
  private var gestureStates: [ObjectIdentifier: GestureState] = [:]

  func update(pdfView: PDFView,
              editing: Bool,
              interactionsEnabled: Bool,
              placementRecognizer: UIGestureRecognizer) {
    guard editing || !interactionsEnabled else {
      restore()
      return
    }

    suppress(pdfView,
             isRoot: true,
             editing: editing && interactionsEnabled,
             placementRecognizer: placementRecognizer)
  }

  private func suppress(_ view: UIView,
                        isRoot: Bool,
                        editing: Bool,
                        placementRecognizer: UIGestureRecognizer) {
    if editing, view is InkSignPdfPageOverlayView { return }

    let containsOverlay = editing && hasOverlayDescendant(view)
    if !isRoot && !containsOverlay {
      remember(view)
      view.isUserInteractionEnabled = false
      return
    }

    if containsOverlay && !isRoot {
      restoreInteraction(for: view)
    }
    for recognizer in view.gestureRecognizers ?? [] {
      if isRoot && editing && recognizer === placementRecognizer { continue }
      remember(recognizer)
      recognizer.isEnabled = false
    }
    for child in view.subviews {
      suppress(child,
               isRoot: false,
               editing: editing,
               placementRecognizer: placementRecognizer)
    }
  }

  private func hasOverlayDescendant(_ view: UIView) -> Bool {
    if view is InkSignPdfPageOverlayView { return true }
    return view.subviews.contains(where: hasOverlayDescendant)
  }

  private func remember(_ view: UIView) {
    let key = ObjectIdentifier(view)
    if viewStates[key] == nil { viewStates[key] = ViewState(view) }
  }

  private func remember(_ recognizer: UIGestureRecognizer) {
    let key = ObjectIdentifier(recognizer)
    if gestureStates[key] == nil { gestureStates[key] = GestureState(recognizer) }
  }

  private func restoreInteraction(for view: UIView) {
    guard let state = viewStates[ObjectIdentifier(view)] else { return }
    view.isUserInteractionEnabled = state.isUserInteractionEnabled
  }

  private func restore() {
    for state in viewStates.values {
      state.view?.isUserInteractionEnabled = state.isUserInteractionEnabled
    }
    for state in gestureStates.values {
      state.recognizer?.isEnabled = state.isEnabled
    }
    viewStates.removeAll()
    gestureStates.removeAll()
  }
}
