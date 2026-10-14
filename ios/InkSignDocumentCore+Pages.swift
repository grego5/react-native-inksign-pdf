import Foundation
import CoreGraphics
import NitroModules

extension InkSignDocumentCore {
  static func localSource(_ source: String) throws -> URL {
    guard !source.isEmpty else { throw InkSignPdfLoadError.invalidSource }
    if let url = URL(string: source), url.scheme != nil {
      guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
        throw InkSignPdfLoadError.invalidSource
      }
      return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    return URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
  }

  func addPages(sources: [String], imageGeometry: PageGeometry?,
                targetDpi: Double?, jpegQuality: Double?, tag: String?) -> Promise<Int> {
    submit {
      try Self.validateTag(tag)
      guard !sources.isEmpty else { return .resolved(withResult: 0) }
      let pageSize = self.coordinator.document?.pages.first?.geometry.displaySize ?? CGSize(width: 595.28, height: 841.89)
      let geometry = imageGeometry ?? PageGeometry(mediaBox: CGRect(origin: .zero, size: pageSize), rotation: 0)
      guard let operation = self.coordinator.admit(.structural) else {
        return .rejected(withError: MutablePageError.operationInProgress)
      }
      let result = InkSignPdfOperationPromise<Int>()
      let coordinator = self.coordinator
      coordinator.pdfQueue.async {
        var staged: [InkSignPdfStagedPageInput] = []
        let staging: Result<[InkSignPdfStagedPageInput], Swift.Error>
        do {
          for source in sources {
            guard coordinator.isCurrent(operation) else { throw MutablePageError.operationCancelled }
            let url = try Self.localSource(source)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf: url)
            let destination = try coordinator.artifactPolicy.allocateStagedInput()
            do { try bytes.write(to: destination, options: .atomic) }
            catch { coordinator.artifactPolicy.deleteExact(destination); throw error }
            staged.append(InkSignPdfStagedPageInput(url: destination,
              type: bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2d]) ? .pdf : .image))
          }
          staging = .success(staged)
        } catch {
          coordinator.releaseStagedInputs(staged)
          staging = .failure(error)
        }
        DispatchQueue.main.async {
          do {
            let inputs = try staging.get()
            guard coordinator.isCurrent(operation) else {
              coordinator.pdfQueue.async { coordinator.releaseStagedInputs(inputs) }
              throw MutablePageError.operationCancelled
            }
            let state = coordinator.document
            let input = InkSignPdfDocumentCoordinator.StructuralInput(operation: operation,
              document: state, pages: state?.pages ?? [], targetPageID: state?.pages.first?.id ?? UUID(),
              targetPageIndex: 0, imageGeometry: geometry, imageTargetDpi: targetDpi,
              imageJpegQuality: jpegQuality, recordHistory: self.recordHistory, tag: tag)
            self.commitStructureNow(input, staged: inputs, command: .append).then { commit in
              result.resolve(commit.addedCount)
            }.catch { error in result.reject(error) }
          } catch {
            coordinator.settle(operation)
            result.reject(error)
          }
        }
      }
      return result.promise
    }
  }

  enum PageMutationPreflight {
    case unchanged
    case mutation(InkSignPdfDocumentState, Int)
  }

  /// Shared policy for viewer preflight and FIFO execution-time revalidation.
  func preflightPageMutation(index: Int, destination: Int? = nil,
                            capturedPage: InkSignPdfCorePageContext? = nil) throws -> PageMutationPreflight {
    try requireAdmittedAccess()
    guard let state = coordinator.document else { throw MutablePageError.invalidPageIndex }
    let targetIndex: Int
    if let capturedPage {
      guard coordinator.generation == capturedPage.generation,
            let resolved = state.index(of: capturedPage.pageID) else {
        throw MutablePageError.operationCancelled
      }
      targetIndex = resolved
    } else {
      guard state.pages.indices.contains(index) else { throw MutablePageError.invalidPageIndex }
      targetIndex = index
    }
    if let destination {
      guard state.pages.indices.contains(destination) else { throw MutablePageError.invalidPageIndex }
      if targetIndex == destination { return .unchanged }
    } else if state.pages.count <= 1 { throw MutablePageError.lastPageRequired }
    return .mutation(state, targetIndex)
  }

  func mutatePage(index: Int, destination: Int? = nil,
                  capturedPage: InkSignPdfCorePageContext? = nil) -> Promise<Void> {
    submit {
      let decision = try self.preflightPageMutation(index: index, destination: destination,
        capturedPage: capturedPage)
      guard case .mutation(let state, let targetIndex) = decision else { return .resolved() }
      guard let operation = self.coordinator.admit(.structural) else {
        return .rejected(withError: MutablePageError.operationInProgress)
      }
      let input = InkSignPdfDocumentCoordinator.StructuralInput(operation: operation, document: state,
        pages: state.pages, targetPageID: state.pages[targetIndex].id, targetPageIndex: targetIndex,
        imageGeometry: state.pages[targetIndex].geometry, imageTargetDpi: nil, imageJpegQuality: nil,
        recordHistory: self.recordHistory, tag: nil)
      let result = InkSignPdfOperationPromise<Void>()
      let command: InkSignPdfDocumentCoordinator.StructuralCommand = destination.map { .move(to: $0) } ?? .remove
      self.commitStructureNow(input, staged: [], command: command).then { _ in
        result.resolve(())
      }.catch { error in result.reject(error) }
      return result.promise
    }
  }

  func rotatePage(index: Int, degrees: Int,
                  capturedPage: InkSignPdfCorePageContext? = nil) -> Promise<Void> {
    submit {
      guard [90, 180, 270].contains(degrees) else { return .rejected(withError: MutablePageError.invalidPageRotation) }
      guard let state = self.coordinator.document else {
        return .rejected(withError: MutablePageError.invalidPageIndex)
      }
      let targetIndex: Int
      if let capturedPage {
        guard self.coordinator.generation == capturedPage.generation,
              let resolved = state.index(of: capturedPage.pageID) else {
          return .rejected(withError: MutablePageError.operationCancelled)
        }
        targetIndex = resolved
      } else {
        guard state.pages.indices.contains(index) else {
          return .rejected(withError: MutablePageError.invalidPageIndex)
        }
        targetIndex = index
      }
      guard let operation = self.coordinator.admit(.structural) else {
        return .rejected(withError: MutablePageError.operationInProgress)
      }
      guard self.coordinator.rotatePage(id: state.pages[targetIndex].id, degrees: degrees, operation: operation) != nil else {
        self.coordinator.settle(operation)
        return .rejected(withError: MutablePageError.operationCancelled)
      }
      self.coordinator.settle(operation)
      self.changed(.structure)
      return .resolved()
    }
  }
}
