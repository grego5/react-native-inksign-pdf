import Foundation
import XCTest
@testable import ReactNativeInkSignPdf

func resolveInputTarget(_ page: any HybridAnalyzedPageSpec,
                        options: InputTargetResolutionOptions) throws -> Double {
  let native = try XCTUnwrap(page as? HybridAnalyzedPage)
  return try native.resolveInputTarget(options: options)
}
