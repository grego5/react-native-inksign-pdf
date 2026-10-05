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

  func displayToRaw(_ point: CGPoint) -> CGPoint {
    switch Self.normalizedRotation(rotation) {
    case 90:
      return CGPoint(x: point.y, y: mediaBox.height - point.x)
    case 180:
      return CGPoint(x: mediaBox.width - point.x, y: mediaBox.height - point.y)
    case 270:
      return CGPoint(x: mediaBox.width - point.y, y: point.x)
    default:
      return point
    }
  }

  func displayToRaw(_ rect: CGRect) -> CGRect {
    let corners = [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.maxX, y: rect.maxY),
    ].map(displayToRaw)
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!,
                  width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  func rawToDisplay(_ point: CGPoint) -> CGPoint {
    switch Self.normalizedRotation(rotation) {
    case 90:
      return CGPoint(x: mediaBox.height - point.y, y: point.x)
    case 180:
      return CGPoint(x: mediaBox.width - point.x, y: mediaBox.height - point.y)
    case 270:
      return CGPoint(x: point.y, y: mediaBox.width - point.x)
    default:
      return point
    }
  }

  func rawToDisplay(_ rect: CGRect) -> CGRect {
    let corners = [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.maxX, y: rect.maxY),
    ].map(rawToDisplay)
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!,
                  width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
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
}
