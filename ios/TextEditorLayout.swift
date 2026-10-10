import UIKit

/// Chooses the wrapping width and measures all lines with the annotation layout.
enum InkSignPdfTextEditorLayout {
  static func measure(_ editor: UITextView,
                      maximumWidth: CGFloat,
                      insets: UIEdgeInsets,
                      fallbackFontSize: CGFloat,
                      isRTL: Bool,
                      fixedContentWidth: CGFloat? = nil) -> CGSize {
    let availableWidth = max(1, maximumWidth - insets.left - insets.right)
    let font = editor.font ?? InkSignPdfTextStyle.font(size: fallbackFontSize)

    func layout(at contentWidth: CGFloat) -> CGFloat {
      editor.textContainer.size = CGSize(width: contentWidth,
                                         height: .greatestFiniteMagnitude)
      editor.layoutManager.ensureLayout(for: editor.textContainer)
      return contentWidthExtent(of: editor, insets: insets)
    }

    var contentWidth: CGFloat
    if let fixedContentWidth {
      contentWidth = min(availableWidth, max(1, fixedContentWidth))
      _ = layout(at: contentWidth)
    } else {
      let availableContentWidth = layout(at: availableWidth)
      contentWidth = editor.text.isEmpty
        ? min(availableWidth, font.pointSize)
        : min(availableWidth, max(1, availableContentWidth))
      let requiredWidth = layout(at: contentWidth)
      if contentWidth < availableWidth, requiredWidth > contentWidth {
        contentWidth = min(availableWidth, requiredWidth)
        _ = layout(at: contentWidth)
      }
    }

    let width = contentWidth + insets.left + insets.right
    let layout = InkSignPdfTextRenderer.layout(text: editor.text ?? "",
                                              fontSize: font.pointSize,
                                              isRTL: isRTL,
                                              contentWidth: contentWidth)
    let presentationInsets = InkSignPdfTextStyle.presentationInsets
    let contentHeight = layout.size.height - presentationInsets.top - presentationInsets.bottom
    let emptyLineHeight = editor.text.last?.isNewline == true ? font.lineHeight : 0
    return CGSize(width: width,
                  height: max(contentHeight + emptyLineHeight, font.lineHeight) + insets.top + insets.bottom)
  }

  private static func contentWidthExtent(of editor: UITextView,
                                        insets: UIEdgeInsets) -> CGFloat {
    let glyphBounds = editor.layoutManager.usedRect(for: editor.textContainer)
    let caretInView = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .null
    let caretInContainer = caretInView.offsetBy(
      dx: editor.contentOffset.x - insets.left,
      dy: editor.contentOffset.y - insets.top)
    let textAndCaretBounds = glyphBounds.union(caretInContainer)
    let widthFromAnchor = editor.textAlignment == .right
      ? editor.textContainer.size.width - textAndCaretBounds.minX
      : textAndCaretBounds.maxX
    return max(widthFromAnchor, 0)
  }
}
