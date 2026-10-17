import Foundation

/// Current admitted text belongs to the core; UIKit holds only its token.
final class InkSignPdfDocumentTextEdit {
  let context: InkSignPdfCorePageContext
  let page: InkSignPdfPageState
  let id: UInt64
  let baseline: InkSignPdfTextAnnotation?
  let initialOptions: InkSignPdfTextTargetOptions
  private let initialPlacement: InkSignPdfTextAnnotation?
  var current: InkSignPdfTextAnnotation? { page.history.textState.target(id).annotation }
  private(set) var active = true

  init(context: InkSignPdfCorePageContext, page: InkSignPdfPageState, id: UInt64, options: InkSignPdfTextTargetOptions) {
    self.context = context; self.page = page; self.id = id
    initialOptions = options
    baseline = page.history.text(for: id)
    initialPlacement = page.history.textState.target(id).placementAnnotation
  }

  func update(_ annotation: InkSignPdfTextAnnotation?) {
    precondition(active && (annotation == nil || annotation?.id == id))
    page.history.applyTextState(id: id, annotation: annotation, changed: baseline != annotation)
  }

  func cancel() {
    precondition(active)
    active = false
    page.history.finishTextState(id: id)
    if baseline == nil { page.history.textState.target(id).retainEmpty(initialPlacement) }
  }

  func end() {
    precondition(active)
    let current = self.current
    active = false
    page.history.finishTextState(id: id)
    guard baseline != current else { return }
    if let baseline {
      if let current { page.history.replaceText(before: baseline, with: current, type: .textEdit) }
      else { page.history.removeText(baseline) }
    } else if let current { page.history.appendText(current) }
  }
}
