import Foundation
import UIKit
import PencilKit

func sanitizePen(
  color: String?,
  maxWidth: Double?
) -> PenValue {
  var value = PenValue()
  if let maxWidth, maxWidth.isFinite, maxWidth > 0 { value.maxWidth = maxWidth }
  if let color, let parsed = parseColor(color) { value.color = parsed }
  return value
}

func parseColor(_ value: String) -> UIColor? {
  guard value.first == "#" else { return nil }
  let hex = String(value.dropFirst())
  guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return nil }
  let red = CGFloat((number >> 16) & 0xFF) / 255
  let green = CGFloat((number >> 8) & 0xFF) / 255
  let blue = CGFloat(number & 0xFF) / 255
  return UIColor(red: red, green: green, blue: blue, alpha: 1)
}

func normalizeTextColor(_ value: String?, fallback: String = "#000000") -> String {
  guard let value, let color = parseColor(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    return fallback
  }
  var red: CGFloat = 0
  var green: CGFloat = 0
  var blue: CGFloat = 0
  var alpha: CGFloat = 0
  guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return fallback }
  return String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
                Int((green * 255).rounded()), Int((blue * 255).rounded()))
}

extension InkSignView {
  func updatePenConfiguration() {
    let color = strokeColor
    let maxWidth = strokeMaxWidth
    performOnMain {
      let value = sanitizePen(
        color: color,
        maxWidth: maxWidth)
      if self.hasDrawingTransaction {
        self.queuedPen = value
      } else {
        self.installPen(value)
      }
    }
  }

  func installPen(_ value: PenValue) {
    currentPen = value
    canvasView.tool = PKInkingTool(.pen, color: value.color,
                                   width: CGFloat(value.maxWidth))
  }
}
