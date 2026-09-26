import UIKit

/// Measures the live TextKit layout and sizes its text container to that result.
enum InkSignPdfTextEditorLayout {
  static func measure(_ editor: UITextView,
                      maximumWidth: CGFloat,
                      insets: UIEdgeInsets,
                      fallbackFontSize: CGFloat) -> CGSize {
    let availableWidth = max(1, maximumWidth - insets.left - insets.right)
    let font = editor.font ?? InkSignPdfTextStyle.font(size: fallbackFontSize)

    func layout(at contentWidth: CGFloat) -> CGSize {
      editor.textContainer.size = CGSize(width: contentWidth,
                                         height: .greatestFiniteMagnitude)
      editor.bounds.size = CGSize(width: contentWidth + insets.left + insets.right,
                                  height: max(editor.bounds.height, font.lineHeight))
      editor.setContentOffset(.zero, animated: false)
      editor.layoutManager.ensureLayout(for: editor.textContainer)
      editor.layoutIfNeeded()
      return extent(of: editor, insets: insets)
    }

    let availableLayout = layout(at: availableWidth)
    var contentWidth = editor.text.isEmpty
      ? min(availableWidth, font.pointSize)
      : min(availableWidth, availableLayout.width)
    var finalLayout = layout(at: contentWidth)
    if contentWidth < availableWidth, finalLayout.width > contentWidth {
      contentWidth = min(availableWidth, finalLayout.width)
      finalLayout = layout(at: contentWidth)
    }

    let size = CGSize(width: contentWidth + insets.left + insets.right,
                      height: max(finalLayout.height, font.lineHeight) +
                        insets.top + insets.bottom)
    editor.bounds.size = size
    editor.setContentOffset(.zero, animated: false)
    editor.layoutManager.ensureLayout(for: editor.textContainer)
    editor.layoutIfNeeded()
    return size
  }

  private static func extent(of editor: UITextView,
                             insets: UIEdgeInsets) -> CGSize {
    let glyphBounds = editor.layoutManager.usedRect(for: editor.textContainer)
    let caretInView = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .null
    let caretInContainer = caretInView.offsetBy(
      dx: editor.contentOffset.x - insets.left,
      dy: editor.contentOffset.y - insets.top)
    let textAndCaretBounds = glyphBounds.union(caretInContainer)
    let widthFromAnchor = editor.textAlignment == .right
      ? editor.textContainer.size.width - textAndCaretBounds.minX
      : textAndCaretBounds.maxX
    return CGSize(width: max(widthFromAnchor, 0),
                  height: max(textAndCaretBounds.maxY, 0))
  }
}
