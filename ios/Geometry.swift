import CoreGraphics
import UIKit

struct PenValue {
  var color: UIColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
  var maxWidth: Double = 4.0
}

struct PageGeometry {
  let mediaBox: CGRect
  let rotation: Int

  static let empty = PageGeometry(mediaBox: .zero, rotation: 0)

  var isValid: Bool {
    mediaBox.minX.isFinite && mediaBox.minY.isFinite &&
      mediaBox.width.isFinite && mediaBox.height.isFinite &&
      mediaBox.width > 0 && mediaBox.height > 0 &&
      [0, 90, 180, 270].contains(Self.normalizedRotation(rotation))
  }

  static func normalizedRotation(_ rotation: Int) -> Int {
    ((rotation % 360) + 360) % 360
  }

  var displaySize: CGSize {
    switch Self.normalizedRotation(rotation) {
    case 90, 270:
      return CGSize(width: mediaBox.height, height: mediaBox.width)
    default:
      return mediaBox.size
    }
  }

  var displayToPDFTransform: CGAffineTransform {
    switch Self.normalizedRotation(rotation) {
    case 90:
      return CGAffineTransform(a: 0, b: 1, c: 1, d: 0,
                               tx: mediaBox.minX, ty: mediaBox.minY)
    case 180:
      return CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                               tx: mediaBox.maxX, ty: mediaBox.minY)
    case 270:
      return CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                               tx: mediaBox.maxX, ty: mediaBox.maxY)
    default:
      return CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                               tx: mediaBox.minX, ty: mediaBox.maxY)
    }
  }

  /// PDF coordinates include the media-box origin and have a bottom-left origin.
  var canonicalToPDFTransform: CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: mediaBox.minX, ty: mediaBox.maxY)
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
    PageGeometry(mediaBox: mediaBox, rotation: rotation).displayToCanonicalTransform
  }

  func layoutToDisplay(rotation: Int) -> CGAffineTransform {
    layoutToCanonical(rotation: rotation).concatenating(canonicalToDisplayTransform)
  }
}
