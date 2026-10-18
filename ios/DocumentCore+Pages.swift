import Foundation
import CoreGraphics
import NitroModules

extension DocumentCore {
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

  func stageInputs(sources: [String]?, type: InkSignPdfPageInputType?) -> Promise<[InkSignPdfStagedPageInput]> {
    let settlement = InkSignPdfOperationPromise<[InkSignPdfStagedPageInput]>()
    inputs.stage(options: InkSignPdfPageInputOptions(type: type, sources: sources)) { result in
      switch result {
      case .success(let staged): settlement.resolve(staged)
      case .failure(let error): settlement.reject(error)
      }
    }
    return settlement.promise
  }

  func addPages(sources: [String]? = nil, imageGeometry: PageGeometry?,
                targetDpi: Double?, jpegQuality: Double?, tag: String?,
                type: InkSignPdfPageInputType? = nil) -> Promise<Int> {
    submit {
      try self.addPagesNow(sources: sources, imageGeometry: imageGeometry,
        targetDpi: targetDpi, jpegQuality: jpegQuality, tag: tag, type: type)
    }
  }

  @discardableResult
  func initialize(options: DocumentOptions?) -> Promise<Int> {
    guard let options, let sources = options.sources, !sources.isEmpty else { return .resolved(withResult: 0) }
    return submit {
      let result = InkSignPdfOperationPromise<Int>()
      do {
        let geometry = try options.imagePageSize.map { size in
          let geometry = PageGeometry(mediaBox: CGRect(x: 0, y: 0, width: size.width, height: size.height), rotation: 0)
          guard geometry.isValid else { throw MutablePageError.assemblyFailed }
          return geometry
        }
        try self.addPagesNow(sources: sources, imageGeometry: geometry,
          targetDpi: options.targetDpi, jpegQuality: options.jpegQuality, tag: options.tag,
          type: options.type.map { $0 == .pdf ? .pdf : .image }, initialImport: true)
          .then { result.resolve($0) }
          .catch { error in self.failInitialization(error); result.reject(error) }
      } catch {
        self.failInitialization(error)
        throw error
      }
      return result.promise
    }
  }

  private func addPagesNow(sources: [String]?, imageGeometry: PageGeometry?,
                           targetDpi: Double?, jpegQuality: Double?, tag: String?,
                           type: InkSignPdfPageInputType?, initialImport: Bool = false) throws -> Promise<Int> {
      try Self.validateTag(tag)
      if sources?.isEmpty == true { return .resolved(withResult: 0) }
      let pageSize = self.coordinator.document?.pages.first?.geometry.displaySize
        ?? CGSize(width: 595.28, height: 841.89)
      let geometry = imageGeometry ?? PageGeometry(mediaBox: CGRect(origin: .zero, size: pageSize), rotation: 0)
      let result = InkSignPdfOperationPromise<Int>()
      let coordinator = self.coordinator
      self.stageInputs(sources: sources, type: type).then { staged in
        guard !staged.isEmpty else { result.resolve(0); return }
        guard let operation = coordinator.admit(.structural) else {
          coordinator.pdfQueue.async { coordinator.releaseStagedInputs(staged) }
          result.reject(MutablePageError.operationCancelled)
          return
        }
        self.endTextEdit()
        self.changed(.structuralWriteStarted)
        let state = coordinator.document
        let input = InkSignPdfDocumentCoordinator.StructuralInput(operation: operation,
          document: state, pages: state?.pages ?? [], targetPageID: state?.pages.first?.id ?? UUID(),
          targetPageIndex: 0, imageGeometry: geometry, imageTargetDpi: targetDpi,
          imageJpegQuality: jpegQuality, recordHistory: self.recordHistory, tag: tag)
        self.commitStructureNow(input, staged: staged, command: .append, initialImport: initialImport).then { commit in
          result.resolve(commit.addedCount)
        }.catch { error in result.reject(error) }
      }.catch { error in result.reject(error) }
      return result.promise
  }

  enum PageMutationPreflight {
    case unchanged
    case mutation(CommittedDocumentState, Int)
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
    }
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
      self.endTextEdit()
      self.changed(.structuralWriteStarted)
      if destination == nil && state.pages.count == 1 {
        let removed = self.coordinator.publishEmptyStructural(operation: operation)
        if let removed { self.coordinator.workingArtifacts.retire(removed.workingURL) }
        self.coordinator.settle(operation)
        self.changed(.structure)
        return removed == nil ? .rejected(withError: Error.closed) : .resolved()
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
      self.endTextEdit()
      self.changed(.structuralWriteStarted)
      guard self.coordinator.rotatePage(id: state.pages[targetIndex].id, degrees: degrees, operation: operation) != nil else {
        self.coordinator.settle(operation)
        self.changed(.structure)
        return .rejected(withError: MutablePageError.operationCancelled)
      }
      self.coordinator.settle(operation)
      self.changed(.structure)
      return .resolved()
    }
  }
}
