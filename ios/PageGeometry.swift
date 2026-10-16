import CoreGraphics
import UIKit

struct PenValue {
  var color: UIColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
  var maxWidth: Double = 4.0
}

struct PageGeometry {
  let mediaBox: CGRect
  let rotation: Int
  let visibleBox: CGRect

  init(mediaBox: CGRect, rotation: Int, visibleBox: CGRect? = nil) {
    self.mediaBox = mediaBox
    self.rotation = rotation
    self.visibleBox = visibleBox ?? mediaBox
  }

  static let empty = PageGeometry(mediaBox: .zero, rotation: 0)

  var isValid: Bool {
    mediaBox.minX.isFinite && mediaBox.minY.isFinite &&
      mediaBox.width.isFinite && mediaBox.height.isFinite &&
      mediaBox.width > 0 && mediaBox.height > 0 &&
      visibleBox.minX.isFinite && visibleBox.minY.isFinite &&
      visibleBox.width.isFinite && visibleBox.height.isFinite &&
      visibleBox.width > 0 && visibleBox.height > 0 && mediaBox.contains(visibleBox) &&
      [0, 90, 180, 270].contains(Self.normalizedRotation(rotation))
  }

  static func normalizedRotation(_ rotation: Int) -> Int {
    ((rotation % 360) + 360) % 360
  }

  var displaySize: CGSize {
    switch Self.normalizedRotation(rotation) {
    case 90, 270:
      return CGSize(width: visibleBox.height, height: visibleBox.width)
    default:
      return visibleBox.size
    }
  }

  var displayToPDFTransform: CGAffineTransform {
    switch Self.normalizedRotation(rotation) {
    case 90:
      return CGAffineTransform(a: 0, b: 1, c: 1, d: 0,
                               tx: visibleBox.minX, ty: visibleBox.minY)
    case 180:
      return CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                               tx: visibleBox.maxX, ty: visibleBox.minY)
    case 270:
      return CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                               tx: visibleBox.maxX, ty: visibleBox.maxY)
    default:
      return CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                               tx: visibleBox.minX, ty: visibleBox.maxY)
    }
  }

  /// PDF coordinates include the visible-box origin and have a bottom-left origin.
  var canonicalToPDFTransform: CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: visibleBox.minX, ty: visibleBox.maxY)
  }

  var displayToCanonicalTransform: CGAffineTransform {
    displayToPDFTransform.concatenating(canonicalToPDFTransform.inverted())
  }

  var canonicalToDisplayTransform: CGAffineTransform { displayToCanonicalTransform.inverted() }

  func displayToCanonical(_ rect: CGRect) -> CGRect { rect.applying(displayToCanonicalTransform) }
  func displayToCanonical(_ point: CGPoint) -> CGPoint { point.applying(displayToCanonicalTransform) }
  func canonicalToDisplay(_ rect: CGRect) -> CGRect { rect.applying(canonicalToDisplayTransform) }
  func canonicalToDisplay(_ point: CGPoint) -> CGPoint { point.applying(canonicalToDisplayTransform) }

  func layoutToCanonical(rotation: Int) -> CGAffineTransform {
    PageGeometry(mediaBox: mediaBox, rotation: rotation, visibleBox: visibleBox).displayToCanonicalTransform
  }

  func layoutToDisplay(rotation: Int) -> CGAffineTransform {
    layoutToCanonical(rotation: rotation).concatenating(canonicalToDisplayTransform)
  }
}
