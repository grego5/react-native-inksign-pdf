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

enum InkSignPdfNativeConfigurationUpdate {
  case pen(color: String?, maxWidth: Double?)
  case defaultTextFontSize(Double?)
  case defaultTextColor(String?)
  case outlineColor(String?)
  case selectedOutlineColor(String?)
  case editorBackgroundColor(String?)
  case selectedBackgroundColor(String?)
  case keyboardAvoidanceEnabled(Bool)
}

extension InkSignView {
  func enqueueNativeConfiguration(_ update: InkSignPdfNativeConfigurationUpdate) {
    performOnMain { [weak self] in self?.applyNativeConfiguration(update) }
  }

  private func applyNativeConfiguration(_ update: InkSignPdfNativeConfigurationUpdate) {
    switch update {
    case .pen(let color, let maxWidth):
      let value = sanitizePen(color: color, maxWidth: maxWidth)
      if hasDrawingTransaction { queuedPen = value } else { installPen(value) }
    case .defaultTextFontSize(let value):
      textInteractionOverlay.setDefaultFontSize(value)
    case .defaultTextColor(let value):
      textInteractionOverlay.setDefaultTextColor(value)
    case .outlineColor(let value):
      textInteractionOverlay.setOutlineColor(value)
    case .selectedOutlineColor(let value):
      textInteractionOverlay.setSelectedOutlineColor(value)
    case .editorBackgroundColor(let value):
      textInteractionOverlay.setEditorBackgroundColor(value)
    case .selectedBackgroundColor(let value):
      textInteractionOverlay.setSelectedBackgroundColor(value)
    case .keyboardAvoidanceEnabled(let value):
      textInteractionOverlay.setKeyboardAvoidanceEnabled(value)
    }
  }

  func installPen(_ value: PenValue) {
    currentPen = value
    updateCanvasPen(canvasView)
  }

  func updateCanvasPen(_ canvas: InkCanvasView) {
    guard !hasDrawingTransaction else { return }
    var width = CGFloat(currentPen.maxWidth)
    if canvas.isDescendant(of: documentView) {
      let origin = canvas.convert(.zero, to: documentView)
      let axis = canvas.convert(CGPoint(x: 1, y: 0), to: documentView)
      let scale = hypot(axis.x - origin.x, axis.y - origin.y) * canvas.zoomScale
      guard scale.isFinite, scale > 0 else { return }
      width /= scale
    }
    if let tool = canvas.tool as? PKInkingTool,
       tool.inkType == .pen, tool.color == currentPen.color, tool.width == width {
      return
    }
    canvas.tool = PKInkingTool(.pen, color: currentPen.color, width: width)
  }
}
