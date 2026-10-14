import Foundation
import NitroModules

extension InkSignView {
  func finalize() throws -> Promise<String> {
    enqueueViewerCommand { self.documentCore.finalize() }
  }

  func startDebugRecording() {}
  func stopDebugRecording() {}
  func exportDebugRecording() throws -> Promise<String> {
    Promise.rejected(withError: InkSignPdfExportError.notReady)
  }
}
