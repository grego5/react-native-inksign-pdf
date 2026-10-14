import Foundation

enum InkSignPdfLoadError: LocalizedError {
  case invalidSource
  case failed
  case empty
  case cancelled

  var errorDescription: String? {
    switch self {
    case .invalidSource: return "invalid_source_path: Source file is not readable"
    case .failed: return "pdf_load_failed: Unable to load the PDF"
    case .empty: return "unsupported_pdf: The PDF has no pages"
    case .cancelled: return "operation_cancelled: PDF load was cancelled"
    }
  }
}

enum InkSignPdfExportError: LocalizedError {
    case notReady
    case invalidOutput
    case cancelled
    case unsupportedContent
    case failed
    case operationInProgress

    var errorDescription: String? {
      switch self {
      case .notReady: return "view_not_ready: The PDF is not ready"
      case .invalidOutput: return "invalid_output_path: The export path is invalid"
      case .cancelled: return "operation_cancelled: PDF export was cancelled"
      case .unsupportedContent: return "pdf_export_unsupported_content: The committed drawing uses unsupported ink"
      case .failed: return "pdf_export_failed: Unable to export the PDF"
      case .operationInProgress: return "operation_in_progress: Another document operation is active"
      }
    }
  }

enum TextError: LocalizedError, CustomStringConvertible {
  case fontNotLoaded
  case notReady
  case notFocused
  case invalidText
  case invalidBounds
  case invalidPageTag
  case cancelled
  case keyNotFound
  case ruleNotFound
  case documentNotOpen
  case pageNotFound
  case textNotFound
  case targetAmbiguous
  case textDoesNotFit

  var errorDescription: String? { description }

  var description: String {
    switch self {
    case .fontNotLoaded: return "font_not_loaded: The requested text font is not loaded"
    case .notReady:
      return "view_not_ready: The PDF view is not ready for text interaction"
    case .notFocused:
      return "text_not_focused: No text annotation is selected"
    case .invalidText:
      return "invalid_text: Text must not be empty"
    case .invalidBounds:
      return "invalid_text_bounds: Text bounds must define an ordered rectangle inside the active page"
    case .invalidPageTag:
      return "invalid_page_tag: Page tags must be nonempty strings"
    case .cancelled:
      return "operation_cancelled: The text request was disposed or superseded"
    case .keyNotFound:
      return "text_key_not_found: The requested text key was not found on the active page"
    case .ruleNotFound:
      return "text_rule_not_found: The selected text key has no usable rule or visible line"
    case .documentNotOpen:
      return "document_not_open: A document must be open before acquiring a prepared page"
    case .pageNotFound:
      return "page_not_found: The requested page index is outside the document"
    case .textNotFound:
      return "text_not_found: The text ID does not belong to this page"
    case .targetAmbiguous:
      return "text_target_ambiguous: The source text target is ambiguous"
    case .textDoesNotFit:
      return "text_does_not_fit: The supplied value does not fit in the text target"
    }
  }
}

enum MutablePageError: LocalizedError {
  case notReady
  case operationInProgress
  case operationCancelled
  case activeInkGesture
  case lastPageRequired
  case invalidPageIndex
  case invalidPageRotation
  case assemblyFailed
  case unsupportedContent

  var errorDescription: String? {
    switch self {
    case .notReady: return "document_not_ready: Open a PDF before changing pages"
    case .operationInProgress: return "operation_in_progress: Another document operation is active"
    case .operationCancelled: return "operation_cancelled: The page operation was cancelled"
    case .activeInkGesture: return "operation_in_progress: Finish the active ink gesture first"
    case .lastPageRequired: return "last_page_required: The document must retain one page"
    case .invalidPageIndex: return "invalid_page_index: The destination page index is invalid"
    case .invalidPageRotation: return "invalid_page_rotation: Page rotation must be 90, 180, or 270 degrees clockwise"
    case .assemblyFailed: return "pdf_mutation_failed: Unable to assemble the updated PDF"
    case .unsupportedContent: return "unsupported_content: The selected image is unreadable"
    }
  }
}
