import CoreGraphics
import PencilKit
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
      [0, 90, 180, 270].contains(((rotation % 360) + 360) % 360)
  }
}
