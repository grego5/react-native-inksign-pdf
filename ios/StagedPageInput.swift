import Foundation

enum InkSignPdfPageInputType: Equatable {
  case pdf
  case image
}

struct InkSignPdfStagedPageInput {
  let url: URL
  let type: InkSignPdfPageInputType
}
