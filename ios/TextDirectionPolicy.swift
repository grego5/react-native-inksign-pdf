import UIKit

enum InkSignPdfTextDirectionPolicy {
  static func appDefaultIsRTL() -> Bool {
    guard let localeLanguage = Locale.current.languageCode?.lowercased() else { return false }
    return ["ar", "he", "fa", "ur"].contains(localeLanguage)
  }

  static func inputLanguageDirectionHint(_ languageTag: String?) -> Bool? {
    guard let language = languageTag?.lowercased(), !language.isEmpty else { return nil }
    if ["ar", "he", "fa", "ur"].contains(where: { language.hasPrefix($0) }) { return true }
    return false
  }

  static func applyWritingDirection(to textView: UITextView, isRTL: Bool) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    let textRange = NSRange(location: 0, length: textView.textStorage.length)
    if textRange.length > 0 {
      textView.textStorage.addAttribute(.paragraphStyle,
                                        value: paragraphStyle,
                                        range: textRange)
    }
    textView.typingAttributes[.paragraphStyle] = paragraphStyle
    textView.textAlignment = isRTL ? .right : .left
    textView.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
  }
}
