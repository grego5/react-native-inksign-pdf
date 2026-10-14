import Foundation

/// Current admitted text belongs to the core; UIKit holds only its token.
final class InkSignPdfDocumentTextEdit {
  let context: InkSignPdfCorePageContext
  let page: InkSignPdfPageState
  let id: UInt64
  let baseline: InkSignPdfTextAnnotation?
  private(set) var current: InkSignPdfTextAnnotation?
  private(set) var active = true

  init(context: InkSignPdfCorePageContext, page: InkSignPdfPageState, id: UInt64) {
    self.context = context; self.page = page; self.id = id
    baseline = page.history.text(for: id)
    current = baseline
  }

  func update(_ annotation: InkSignPdfTextAnnotation?) {
    precondition(active && (annotation == nil || annotation?.id == id))
    current = annotation
    page.history.textPreview = .init(id: id, annotation: annotation, changed: baseline != annotation)
  }

  func end() {
    precondition(active)
    active = false
    page.history.textPreview = nil
    guard baseline != current else { return }
    if let baseline {
      if let current { page.history.replaceText(before: baseline, with: current, type: .textEdit) }
      else { page.history.removeText(baseline) }
    } else if let current { page.history.appendText(current) }
  }
}
