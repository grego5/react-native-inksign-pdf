import CoreGraphics

/// The sole current module value for a target. Empty placement is retained only on removal.
final class InkSignPdfTextTargetState {
  private(set) var annotation: InkSignPdfTextAnnotation?
  private var emptyAnnotation: InkSignPdfTextAnnotation?
  var placementAnnotation: InkSignPdfTextAnnotation? { annotation ?? emptyAnnotation }

  func retainEmpty(_ placement: InkSignPdfTextAnnotation?) {
    precondition(annotation == nil)
    emptyAnnotation = placement
  }

  func apply(_ next: InkSignPdfTextAnnotation?) {
    if next == nil {
      if let annotation { emptyAnnotation = annotation }
    } else { emptyAnnotation = nil }
    annotation = next
  }
}

/// Core page state application, shared by direct edits and history restoration.
final class InkSignPdfPageTextState {
  private var targets: [UInt64: InkSignPdfTextTargetState] = [:]
  private(set) var order: [UInt64] = []
  func target(_ id: UInt64) -> InkSignPdfTextTargetState {
    if let target = targets[id] { return target }
    let target = InkSignPdfTextTargetState()
    targets[id] = target
    return target
  }
  var annotations: [InkSignPdfTextAnnotation] { order.compactMap { targets[$0]?.annotation } }
  func apply(_ annotations: [InkSignPdfTextAnnotation]) {
    let next = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })
    for (id, target) in targets { target.apply(next[id]) }
    for annotation in annotations where targets[annotation.id] == nil { target(annotation.id).apply(annotation) }
    order = annotations.map(\.id)
  }
  func apply(id: UInt64, annotation: InkSignPdfTextAnnotation?) {
    precondition(annotation == nil || annotation?.id == id)
    target(id).apply(annotation)
    order.removeAll { $0 == id }
    if annotation != nil { order.append(id) }
  }
}
