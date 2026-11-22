import CoreGraphics
import PDFKit

extension ViewerCanvas {
  var acceptsSourceTextSelection: Bool {
    !disposed && container.window != nil && interaction.inputEnabled && interaction.mode == .view
  }

  /// PDFKit yields absolute bottom-left PDF space; analysis is visible-box-relative top-left.
  func sourceCanonicalPoint(_ point: CGPoint) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite, let state = viewerDocument else { return nil }
    return documentView.convert(point, to: state.activePDFPage)
      .applying(state.activePage.geometry.canonicalToPDFTransform.inverted())
  }

  var sourceTouchTolerance: CGFloat { 8 / documentView.scaleFactor }
}
