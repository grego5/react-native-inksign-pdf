import CoreGraphics
import Foundation
import PDFKit
import NitroModules

struct InkSignPdfKeyRulePlacement {
  let match: InkSignPdfKeyTextMatch
  let rule: InkSignPdfPlacementRule
  let contentMinX: CGFloat
  let contentMaxX: CGFloat
}

private struct InkSignPdfKeyRuleFit {
  let rule: InkSignPdfPlacementRule
  let contentMinX: CGFloat
  let contentMaxX: CGFloat
  let horizontalGap: CGFloat
  let verticalGap: CGFloat
}

private let keyInsertionLabelMarginPoints: CGFloat = 2

enum InkSignPdfKeyRuleSelector {
  static func select(matches: [InkSignPdfKeyTextMatch],
                     rules: [InkSignPdfPlacementRule],
                     occurrence: TextKeyOccurrence,
                     directionRtl: Bool,
                     pageSize: CGSize) -> InkSignPdfKeyRulePlacement? {
    let orderedMatches = matches.sorted {
      if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
      if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
      return $0.sourceIndex < $1.sourceIndex
    }
    for matchIndex in orderedMatches.indices {
      let orderedIndex: Int
      switch occurrence {
      case .first: orderedIndex = matchIndex
      case .last: orderedIndex = orderedMatches.count - matchIndex - 1
      }
      let match = orderedMatches[orderedIndex]
      let centerY = match.lineCenterY ?? match.bounds.midY
      guard match.lineHeight.isFinite, match.lineHeight > 0, centerY.isFinite else { continue }

      var bestFit: InkSignPdfKeyRuleFit?
      for candidate in rules {
        guard candidate.minX.isFinite && candidate.maxX.isFinite && candidate.y.isFinite &&
          candidate.minX >= 0 && candidate.maxX <= pageSize.width && candidate.maxX > candidate.minX &&
          candidate.y >= 0 && candidate.y <= pageSize.height else { continue }
        let overlapsLabel = directionRtl
          ? candidate.maxX > match.bounds.minX
          : candidate.minX < match.bounds.maxX
        let isOnDirectionSide = directionRtl
          ? candidate.minX < match.bounds.minX
          : candidate.maxX > match.bounds.maxX
        let contentMinX = directionRtl || !overlapsLabel
          ? candidate.minX
          : match.bounds.maxX + keyInsertionLabelMarginPoints
        let contentMaxX = !directionRtl || !overlapsLabel
          ? candidate.maxX
          : match.bounds.minX - keyInsertionLabelMarginPoints
        let horizontalGap = directionRtl
          ? match.bounds.minX - contentMaxX
          : contentMinX - match.bounds.maxX
        let verticalGap = abs(candidate.y - centerY)
        guard isOnDirectionSide, contentMaxX > contentMinX, horizontalGap >= 0,
              verticalGap <= match.lineHeight else { continue }

        let isBetter: Bool
        if let current = bestFit {
          if horizontalGap != current.horizontalGap {
            isBetter = horizontalGap < current.horizontalGap
          } else if verticalGap != current.verticalGap {
            isBetter = verticalGap < current.verticalGap
          } else if candidate.minX != current.rule.minX {
            isBetter = candidate.minX < current.rule.minX
          } else {
            isBetter = candidate.y < current.rule.y
          }
        } else {
          isBetter = true
        }
        if isBetter {
          bestFit = InkSignPdfKeyRuleFit(rule: candidate,
                                         contentMinX: contentMinX,
                                         contentMaxX: contentMaxX,
                                         horizontalGap: horizontalGap,
                                         verticalGap: verticalGap)
        }
      }
      if let bestFit {
        return InkSignPdfKeyRulePlacement(match: match,
                                          rule: bestFit.rule,
                                          contentMinX: bestFit.contentMinX,
                                          contentMaxX: bestFit.contentMaxX)
      }
    }
    return nil
  }
}

extension InkSignView {
  func allocateTextAnnotationID() -> String {
    nextTextAnnotationID &+= 1
    return "text-\(nextTextAnnotationID)"
  }

  func insertAnnotationOn(options: TextPlacementOptions?) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      if self.textInteractionOverlay.hasPendingPlacement() { return }
      try self.requireViewportReady(request: .preserve)
      self.textInteractionOverlay.finishForLifecycle()
      self.setInteractionMode(editing: false)
      try self.textInteractionOverlay.armPlacement(generation: self.documentCoordinator.generation,
                                                  options: options)
    }
  }

  func insertAnnotationOff() throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.cancelPendingPlacement()
    }
  }

  func setTextDirection(direction: TextDirection) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func addTextAnnotation(
    text: String,
    bounds: TextAnnotationBounds,
    options: TextAnnotationOptions?
  ) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      try self.textInteractionOverlay.addTextAnnotation(text: text,
                                                         bounds: bounds,
                                                         options: options)
    }
  }

  func insertTextByKey(text: String,
                       key: String,
                       options: TextInsertionByKeyOptions?) throws -> Promise<Void> {
    let captured = try performOnMainSync { () throws -> (URL, UInt64, Int, UUID, CGRect, CGSize, Bool) in
      guard !self.disposed else { throw TextError.cancelled }
      guard let document = self.documentCoordinator.document,
            document.activePageIndex >= 0,
            document.activePageIndex < document.pages.count else { throw TextError.notReady }
      let page = document.activePage
      return (document.workingURL,
              self.documentCoordinator.generation,
              document.activePageIndex,
              page.id,
              page.geometry.mediaBox,
              page.geometry.mediaBox.size,
              self.textInteractionOverlay.resolvedDirection(options?.direction))
    }
    let coordinator = documentCoordinator
    let occurrence = options?.occurrence ?? .first
    let anchor = options?.verticalAnchor ?? .bottom
    let direction = captured.6 ? TextDirection.rtl : TextDirection.ltr
    let commitOptions = TextAnnotationOptions(direction: direction,
                                              maxLines: options?.maxLines,
                                              alignment: options?.alignment ?? .start,
                                              verticalAnchor: anchor)
    let settlement = InkSignPdfOperationPromise<Void>()
    guard let pendingID = coordinator.registerPending(generation: captured.1, handler: {
      settlement.reject(InkSignView.TextError.cancelled)
    }) else {
      settlement.reject(InkSignView.TextError.cancelled)
      return settlement.promise
    }
    coordinator.pdfQueue.async {
      let result: Result<Void, Error>
      do {
      guard let analysis = coordinator.pageAnalysis(sourceURL: captured.0,
                                                    generation: captured.1,
                                                    pageIndex: captured.2,
                                                    pageID: captured.3,
                                                    mediaBox: captured.4) else {
        throw InkSignView.TextError.keyNotFound
      }
      let textLookup = analysis.lookup(key: key)
      guard textLookup.hasLiteralMatch else { throw InkSignView.TextError.keyNotFound }
      let rtl = captured.6
      guard let placement = InkSignPdfKeyRuleSelector.select(matches: textLookup.matches,
                                                              rules: analysis.rules,
                                                              occurrence: occurrence,
                                                              directionRtl: rtl,
                                                              pageSize: captured.5) else {
        throw InkSignView.TextError.ruleNotFound
      }
      let selectedRule = placement.rule
      guard
            selectedRule.y > 0, selectedRule.y < captured.5.height,
            selectedRule.maxX > selectedRule.minX else { throw InkSignView.TextError.ruleNotFound }
      let bounds: TextAnnotationBounds
      switch anchor {
      case .bottom:
        bounds = TextAnnotationBounds(x: placement.contentMinX, y: 0,
                                      width: placement.contentMaxX - placement.contentMinX,
                                      height: selectedRule.y)
      case .top:
        bounds = TextAnnotationBounds(x: placement.contentMinX, y: selectedRule.y,
                                      width: placement.contentMaxX - placement.contentMinX,
                                      height: captured.5.height - selectedRule.y)
      }
      try DispatchQueue.main.sync {
        guard !self.disposed,
              self.documentCoordinator.generation == captured.1,
              let current = self.documentCoordinator.document,
              current.index(of: captured.3) != nil else { throw InkSignView.TextError.cancelled }
        try self.textInteractionOverlay.addTextAnnotation(text: text,
                                                           bounds: bounds,
                                                           options: commitOptions,
                                                           resolvedDirectionRtl: captured.6,
                                                           requireVisibleLine: true,
                                                           capturedPage: (captured.1, captured.3, captured.5))
      }
      result = .success(())
      } catch {
        let stillCurrent = DispatchQueue.main.sync {
          !self.disposed && self.documentCoordinator.generation == captured.1 &&
            self.documentCoordinator.document?.index(of: captured.3) != nil
        }
        result = .failure(stillCurrent ? error : InkSignView.TextError.cancelled)
      }
      DispatchQueue.main.async {
        guard coordinator.completePending(pendingID) else { return }
        let stillCurrent = !self.disposed && coordinator.generation == captured.1 &&
          coordinator.document?.index(of: captured.3) != nil
        guard stillCurrent else {
          settlement.reject(InkSignView.TextError.cancelled)
          return
        }
        switch result {
        case .success:
          settlement.resolve(())
        case .failure(let error):
          settlement.reject(error)
        }
      }
    }
    return settlement.promise
  }

  func increaseTextSize() throws -> Double {
    try performOnMainSync { try self.textInteractionOverlay.increaseTextSize() }
  }

  func decreaseTextSize() throws -> Double {
    try performOnMainSync { try self.textInteractionOverlay.decreaseTextSize() }
  }

  func removeTextAnnotation() throws {
    try performOnMainSync { try self.textInteractionOverlay.removeTextAnnotation() }
  }

  func activeTextAnnotations() -> [InkSignPdfTextAnnotation] {
    documentCoordinator.document?.activePage.history.content.textAnnotations ?? []
  }

  func activePageSize() -> CGSize {
    documentCoordinator.document?.activePage.geometry.mediaBox.size ?? .zero
  }

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.appendText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func appendTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageID: UUID
  ) throws {
    guard !disposed,
          documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          let target = state.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    let targetIsActive = state.activePageID == pageID
    if targetIsActive { cancelActiveStroke() }
    guard target.history.appendText(annotation) else { return }
    if targetIsActive { textInteractionOverlay.syncContent() }
    emitChange()
  }

  func replaceTextAnnotation(
    _ before: InkSignPdfTextAnnotation,
    with after: InkSignPdfTextAnnotation,
    type: InkSignPdfPageContentActionType,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
  guard state.activePage.history.replaceText(before: before, with: after, type: type) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }

  func removeTextAnnotation(
    _ annotation: InkSignPdfTextAnnotation,
    generation: UInt64,
    pageIndex: Int
  ) {
    guard !disposed, self.documentCoordinator.generation == generation,
          let state = documentCoordinator.document,
          state.activePageIndex == pageIndex else { return }
    cancelActiveStroke()
    guard state.activePage.history.removeText(annotation) else { return }
    textInteractionOverlay.syncContent()
    emitChange()
  }
}
