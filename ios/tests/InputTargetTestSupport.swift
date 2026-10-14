import Foundation
import XCTest
@testable import ReactNativeInkSignPdf

func resolveInputTarget(_ page: any HybridDocumentPageSpec,
                        options: ResolveInputUnderlineOptions) throws -> Double {
  try page.resolveInputUnderline(options: options)
}

func createInputTarget(_ page: any HybridDocumentPageSpec,
                       options: CreateInputAreaOptions) throws -> Double {
  try page.createInputArea(options: options)
}
