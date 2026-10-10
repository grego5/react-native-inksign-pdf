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
                     directionRtl: Bool?,
                     pageSize: CGSize) -> InkSignPdfKeyRulePlacement? {
    let directions = directionRtl.map { [$0] } ?? [false, true]
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
        for rtl in directions {
          let overlapsLabel = rtl
            ? candidate.maxX > match.bounds.minX
            : candidate.minX < match.bounds.maxX
          let isOnDirectionSide = rtl
            ? candidate.minX < match.bounds.minX
            : candidate.maxX > match.bounds.maxX
          let contentMinX = rtl || !overlapsLabel
            ? candidate.minX
            : match.bounds.maxX + keyInsertionLabelMarginPoints
          let contentMaxX = !rtl || !overlapsLabel
            ? candidate.maxX
            : match.bounds.minX - keyInsertionLabelMarginPoints
          let horizontalGap = rtl
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
  func setTextDirection(direction: TextDirection) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func getPage(pageIndex: Double?) throws -> Promise<any HybridAnalyzedPageSpec> {
    return enqueueViewerCommand { try self.getPageNow(pageIndex: pageIndex) }
  }

  func getSessionPage(_ token: InkSignPdfModeSessionToken, pageIndex: Double?) throws -> Promise<any HybridAnalyzedPageSpec> {
    try interaction.requireSession(token)
    guard let document = documentCoordinator.document else { throw TextError.cancelled }
    let index = pageIndex ?? Double(document.activePageIndex)
    guard index.isFinite, index >= 0, index.rounded(.towardZero) == index,
          index < Double(document.pages.count) else { throw TextError.pageNotFound }
    let pageID = document.pages[Int(index)].id
    return enqueueViewerCommand(modeSession: token) {
      try self.getPageNow(pageIndex: nil, modeSession: token, capturedPageID: pageID)
    }
  }

  private func getPageNow(pageIndex: Double?, modeSession: InkSignPdfModeSessionToken? = nil,
                          capturedPageID: UUID? = nil) throws -> Promise<any HybridAnalyzedPageSpec> {
    let captured = try performOnMainSync { () throws -> (URL, UInt64, Int, UUID, CGRect) in
      guard !self.disposed else { throw TextError.cancelled }
      guard let document = self.documentCoordinator.document else { throw TextError.documentNotOpen }
      let index: Int
      if let capturedPageID {
        guard let found = document.pages.firstIndex(where: { $0.id == capturedPageID }) else { throw TextError.cancelled }
        index = found
      } else if let pageIndex {
        guard pageIndex.isFinite, pageIndex >= 0, pageIndex.rounded(.towardZero) == pageIndex else {
          throw TextError.pageNotFound
        }
        guard pageIndex < Double(document.pages.count) else { throw TextError.pageNotFound }
        index = Int(pageIndex)
      } else {
        index = document.activePageIndex
      }
      let page = document.pages[index]
      return (document.workingURL, self.documentCoordinator.generation, index, page.id, page.geometry.mediaBox)
    }
    let coordinator = documentCoordinator
    let settlement = InkSignPdfOperationPromise<any HybridAnalyzedPageSpec>()
    guard let pendingID = coordinator.registerPending(generation: captured.1, handler: {
      settlement.reject(TextError.cancelled)
    }) else {
      settlement.reject(TextError.cancelled)
      return settlement.promise
    }
    coordinator.pdfQueue.async {
      let result: Result<InkSignPdfPageAnalysis, Error>
      if let analysis = coordinator.pageAnalysis(sourceURL: captured.0, generation: captured.1,
        pageIndex: captured.2, pageID: captured.3, mediaBox: captured.4) {
        result = .success(analysis)
      } else {
        result = .failure(TextError.cancelled)
      }
      DispatchQueue.main.async {
        guard coordinator.completePending(pendingID) else { return }
        guard !self.disposed, coordinator.generation == captured.1,
              coordinator.document?.pages.contains(where: { $0.id == captured.3 }) == true else {
          settlement.reject(TextError.cancelled)
          return
        }
        do {
          let analysis = try result.get()
          if let modeSession { try self.interaction.requireSession(modeSession) }
          if !coordinator.textTargets(for: captured.3).isEmpty { coordinator.retainTextAnalysis(analysis) }
          settlement.resolve(HybridAnalyzedPage(owner: self, generation: captured.1,
            pageID: captured.3, analysis: analysis, modeSession: modeSession))
        } catch {
          settlement.reject(error)
        }
      }
    }
    return settlement.promise
  }

  func resolvePreparedText(_ handle: HybridAnalyzedPage, options: ResolveTextOptions) throws -> Double {
    try validateTextPageContext(handle)
    guard let document = documentCoordinator.document,
          let page = document.pages.first(where: { $0.id == handle.pageID }) else { throw TextError.cancelled }
    let geometry = page.geometry
    documentCoordinator.retainTextAnalysis(handle.analysis)
    let fieldBounds: CGRect
    var identity: String?
    var embeddedValue = ""
    var selectedRule: InkSignPdfCanonicalWritingRule?
    var excludedSourceRanges: [NSRange] = []
    var detectionBounds: CGRect
    if let fieldName = options.fieldName {
      let lookup = handle.analysis.lookup(key: fieldName)
      guard lookup.hasLiteralMatch else { throw TextError.keyNotFound }
      let displayed = handle.analysis.displayedFieldGeometry(lookup: lookup,
        geometry: geometry)
      let candidates = displayed.matches.filter { match in
        guard let bounds = options.bounds else { return true }
        let region = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        return region.contains(match.bounds)
      }
      guard let placement = InkSignPdfKeyRuleSelector.select(matches: candidates, rules: displayed.rules,
        occurrence: options.occurrence ?? .first,
        directionRtl: textInteractionOverlay.resolvedDirection(options.direction),
        pageSize: geometry.displaySize) else { throw TextError.ruleNotFound }
      guard placement.rule.y > 0, placement.rule.y < geometry.displaySize.height else { throw TextError.ruleNotFound }
      let anchor = options.verticalAnchor ?? .bottom
      fieldBounds = anchor == .bottom
        ? CGRect(x: placement.contentMinX, y: 0,
                 width: placement.contentMaxX - placement.contentMinX, height: placement.rule.y)
        : CGRect(x: placement.contentMinX, y: placement.rule.y,
                 width: placement.contentMaxX - placement.contentMinX,
                 height: geometry.displaySize.height - placement.rule.y)
      guard let ruleIndex = displayed.rules.firstIndex(of: placement.rule) else { throw TextError.ruleNotFound }
      let sourceRule = displayed.sourceRules[ruleIndex]
      selectedRule = sourceRule
      guard let label = handle.analysis.labelCandidates.first(where: { $0.match.sourceIndex == placement.match.sourceIndex }) else {
        preconditionFailure("Selected label is missing from its prepared analysis")
      }
      identity = "\(label.identity)|\(sourceRule.sourceIndex)"
      excludedSourceRanges = label.sourceRanges
      detectionBounds = CGRect(x: placement.rule.minX,
        y: anchor == .bottom ? placement.rule.y - placement.match.lineHeight : placement.rule.y,
        width: placement.rule.maxX - placement.rule.minX, height: placement.match.lineHeight)
    } else {
      guard let bounds = options.bounds else { throw TextError.invalidBounds }
      fieldBounds = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
      guard validPreparedBounds(fieldBounds, pageSize: geometry.displaySize) else { throw TextError.invalidBounds }
      detectionBounds = fieldBounds
    }
    let canonicalBounds = geometry.displayToCanonical(fieldBounds)
    let canonicalDetectionBounds = geometry.displayToCanonical(detectionBounds)
    embeddedValue = handle.analysis.embeddedText(in: canonicalDetectionBounds, excluding: excludedSourceRanges)
    let occupied = page.history.content.textAnnotations.filter {
      let bounds = $0.bounds.applying(geometry.layoutToDisplay(rotation: $0.layoutRotation))
      return bounds.minX < detectionBounds.maxX && bounds.maxX > detectionBounds.minX &&
        bounds.minY < detectionBounds.maxY && bounds.maxY > detectionBounds.minY
    }
    guard occupied.count <= 1 else { throw TextError.targetAmbiguous }
    let target: InkSignPdfTextTarget
    if let existing = documentCoordinator.findTextTarget(pageID: page.id, sourceIdentity: identity,
                                                         canonicalBounds: canonicalBounds) { return Double(existing.id) }
    if let annotation = occupied.first {
      target = try documentCoordinator.adoptTextTarget(id: annotation.id, pageID: page.id,
        sourceIdentity: identity, fieldName: options.fieldName, canonicalBounds: canonicalBounds,
        embeddedValue: embeddedValue, canonicalWritingRule: selectedRule,
        canonicalDetectionBounds: canonicalDetectionBounds, excludedSourceRanges: excludedSourceRanges)
    } else {
      target = try documentCoordinator.reserveTextTarget(pageID: page.id, sourceIdentity: identity,
        fieldName: options.fieldName, canonicalBounds: canonicalBounds, options: options.annotationOptions,
        embeddedValue: embeddedValue, canonicalWritingRule: selectedRule,
        canonicalDetectionBounds: canonicalDetectionBounds, excludedSourceRanges: excludedSourceRanges)
    }
    return Double(target.id)
  }

  func getSelectedText() throws -> Variant__any_HybridTextHandleSpec__NullType {
    try performOnMainSync {
      guard !disposed, let selection = textInteractionOverlay.selectedText,
            let pageID = UUID(uuidString: selection.pageId) else { return .second(.null) }
      return .first(HybridTextHandle(owner: self, generation: documentCoordinator.generation,
                                    pageID: pageID, textID: selection.textId))
    }
  }

  func preparedTextValue(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> String {
    let (page, target) = try preparedTarget(handle, id: id)
    return textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
      ?? page.history.content.textAnnotations.first(where: { $0.id == target.id })?.text
      ?? target.embeddedValue
  }

  func setPreparedTextValue(_ handle: any InkSignPdfTextPageContext, id: Double, text: String) throws {
    let (page, target) = try preparedTarget(handle, id: id)
    if text.isEmpty {
      textInteractionOverlay.clearPreparedDraft(id: target.id, pageID: page.id)
      if let current = page.history.content.textAnnotations.first(where: { $0.id == target.id }) {
        try removeTextAnnotation(current, generation: handle.generation, pageID: page.id)
      }
      return
    }
    if try textInteractionOverlay.setPreparedDraftText(id: target.id, pageID: page.id, text: text) { return }
    let current = page.history.content.textAnnotations.first(where: { $0.id == target.id })
    if let current {
      guard current.text != text else { return }
      let updated = current.replacingText(text, pageSize: PageGeometry(mediaBox: page.geometry.mediaBox, rotation: current.layoutRotation).displaySize)
      try replaceTextAnnotation(current, with: updated, type: .textEdit,
                                generation: handle.generation, pageID: page.id)
    } else {
      let bounds = displayedTargetBounds(target, page: page)
      _ = try displayedWritingRule(target, page: page)
      try textInteractionOverlay.addTextAnnotation(text: text,
        bounds: TextAnnotationBounds(x: Double(bounds.minX), y: Double(bounds.minY),
          width: Double(bounds.width), height: Double(bounds.height)),
        options: target.annotationOptions, capturedPage: (handle.generation, page.id,
          page.geometry.displaySize, page.geometry.rotation),
        targetID: target.id)
    }
  }

  func setPreparedTextOptions(_ handle: any InkSignPdfTextPageContext, id: Double,
                              options: TextAnnotationOptions) throws {
    let (page, target) = try preparedTarget(handle, id: id)
    try documentCoordinator.updateTextTarget(target.id, pageID: page.id) {
      if let value = options.fontSize { $0.options.fontSize = value }
      if let value = options.color { $0.options.color = value }
      if let value = options.direction { $0.options.direction = value }
      if let value = options.maxLines { $0.options.maxLines = Int(value) }
      if let value = options.alignment { $0.options.alignment = value }
      if let value = options.verticalAnchor { $0.options.verticalAnchor = value }
    }
    if textInteractionOverlay.setPreparedDraftOptions(id: target.id, pageID: page.id, options: options) { return }
    guard let current = page.history.content.textAnnotations.first(where: { $0.id == target.id }) else { return }
    let fontSize = CGFloat(options.fontSize ?? Double(current.fontSize))
    let styled = InkSignPdfTextAnnotation(id: current.id, text: current.text, bounds: current.bounds,
      fontSize: fontSize, textColor: options.color ?? current.textColor,
      isRTL: options.direction.map { textInteractionOverlay.resolvedDirection($0) } ?? current.isRTL,
      flowBounds: current.flowBounds, maxLines: Int(options.maxLines ?? Double(current.maxLines)),
      verticalAnchor: options.verticalAnchor.map(InkSignPdfTextVerticalAnchor.init) ?? current.verticalAnchor,
      alignment: options.alignment.map(InkSignPdfTextAlignment.init) ?? current.alignment,
      layoutRotation: current.layoutRotation)
    let updated = styled.replacingText(styled.text,
      pageSize: PageGeometry(mediaBox: page.geometry.mediaBox, rotation: current.layoutRotation).displaySize)
    if updated != current {
      try replaceTextAnnotation(current, with: updated, type: .textEdit,
                                generation: handle.generation, pageID: page.id)
    }
  }

  func preparedTextEntry(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> TextEntry {
    let (page, target) = try preparedTarget(handle, id: id)
    let draft = textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
    let annotation = page.history.content.textAnnotations.first(where: { $0.id == target.id })
    let value = draft ?? annotation?.text ?? target.embeddedValue
    let source: TextValueSource = draft != nil || annotation != nil ? .annotation
      : (!target.embeddedValue.isEmpty ? .embedded : .empty)
    let bounds = displayedTargetBounds(target, page: page)
    return TextEntry(id: Double(target.id), value: value, fieldName: target.fieldName,
      bounds: TextAnnotationBounds(x: Double(bounds.minX), y: Double(bounds.minY),
        width: Double(bounds.width), height: Double(bounds.height)),
      valueSource: source)
  }

  func adjustPreparedTextSize(_ handle: any InkSignPdfTextPageContext, id: Double, delta: Double) throws -> Double {
    let (page, target) = try preparedTarget(handle, id: id)
    let size = textInteractionOverlay.preparedFontSize(id: target.id, pageID: page.id)
      ?? page.history.content.textAnnotations.first(where: { $0.id == target.id }).map { Double($0.fontSize) }
      ?? target.options.fontSize ?? textInteractionOverlay.preparedDefaultFontSize
    let adjusted = textInteractionOverlay.adjustedFontSize(size, delta: delta)
    if adjusted != size {
      let options = TextAnnotationOptions(fontSize: adjusted, color: nil, direction: nil,
        maxLines: nil, alignment: nil, verticalAnchor: nil)
      try setPreparedTextOptions(handle, id: id, options: options)
    }
    return adjusted
  }

  func preparedTextEntries(_ handle: any InkSignPdfTextPageContext) throws -> [TextEntry] {
    try validateTextPageContext(handle)
    return try documentCoordinator.textTargets(for: handle.pageID).map {
      try preparedTextEntry(handle, id: Double($0.id))
    }
  }

  func focusPreparedText(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: TextFocusOptions?) throws -> Promise<Void> {
    return enqueueViewerCommand(presentation: true, modeSession: handle.modeSession) {
      try self.focusPreparedTextNow(handle, id: id, options: options)
    }
  }

  private func focusPreparedTextNow(_ handle: any InkSignPdfTextPageContext, id: Double,
                         options: TextFocusOptions?) throws -> Promise<Void> {
    let (page, target) = try preparedTarget(handle, id: id)
    let rule = try displayedWritingRule(target, page: page)
    let bounds = displayedTargetBounds(target, page: page)
    let geometryRevision = page.geometryRevision
    let result = InkSignPdfOperationPromise<Void>()
    performOnMain {
      guard !self.disposed, self.documentCoordinator.generation == handle.generation else {
        result.reject(TextError.cancelled); return
      }
      guard let document = self.documentCoordinator.document,
            let index = document.index(of: handle.pageID) else { result.reject(TextError.cancelled); return }
      let requestID = self.interaction.viewport.supersede()
      let runFocus = {
        guard !self.disposed, self.interaction.viewport.requestID == requestID,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true,
              self.documentCoordinator.document?.activePage.id == handle.pageID else {
          result.reject(TextError.cancelled); return
        }
        guard self.interaction.finishInteraction(), self.interaction.viewport.requestID == requestID,
              self.documentCoordinator.generation == handle.generation,
              self.documentCoordinator.document?.activePage.id == handle.pageID,
              page.geometryRevision == geometryRevision,
              handle.modeSession.map(self.interaction.sessionIsCurrent) ?? true else {
          result.reject(TextError.cancelled); return
        }
        guard let viewportTarget = self.interaction.viewport.fieldFocusTarget(ruleY: rule?.y ?? bounds.midY,
          horizontalFocus: rule.map { ($0.minX + $0.maxX) / 2 } ?? bounds.midX, zoom: options?.zoom ?? 2,
          verticalAnchor: options?.verticalAnchor ?? .center, edgeOffset: options?.edgeOffset ?? 0)
          else { result.reject(TextError.notReady); return }
        self.interaction.viewport.animateViewport(target: viewportTarget, modeSession: handle.modeSession) { outcome in
          switch outcome {
          case .success: result.resolve(())
          case .failure(let error): result.reject(error)
          }
        }
      }
      if index == document.activePageIndex { runFocus() }
      else {
        do {
          try self.switchPage(to: index) { outcome in
            switch outcome { case .success: runFocus(); case .failure(let error): result.reject(error) }
          }
        } catch { result.reject(error) }
      }
    }
    return result.promise
  }

  private func validateTextPageContext(_ handle: any InkSignPdfTextPageContext) throws {
    if let token = handle.modeSession { try interaction.requireSession(token) }
    guard !disposed, documentCoordinator.generation == handle.generation,
          documentCoordinator.document?.pages.contains(where: { $0.id == handle.pageID }) == true else {
      throw TextError.cancelled
    }
  }

  private func preparedTarget(_ handle: any InkSignPdfTextPageContext, id: Double) throws -> (InkSignPdfPageState, InkSignPdfTextTarget) {
    try validateTextPageContext(handle)
    guard id.isFinite, id >= 1, id.rounded(.towardZero) == id, id <= 9_007_199_254_740_991,
          let document = documentCoordinator.document,
          let page = document.pages.first(where: { $0.id == handle.pageID }) else { throw TextError.textNotFound }
    return (page, try documentCoordinator.textTarget(UInt64(id), pageID: handle.pageID))
  }

  private func validPreparedBounds(_ bounds: CGRect, pageSize: CGSize) -> Bool {
    bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
      bounds.width > 0 && bounds.height > 0 && bounds.minX >= 0 && bounds.minY >= 0 &&
      bounds.maxX <= pageSize.width && bounds.maxY <= pageSize.height
  }

  private func displayedTargetBounds(_ target: InkSignPdfTextTarget, page: InkSignPdfPageState) -> CGRect {
    if let rule = target.canonicalWritingRule {
      let start = page.geometry.canonicalToDisplay(rule.start)
      let end = page.geometry.canonicalToDisplay(rule.end)
      if abs(start.y - end.y) <= 0.001 {
        let bottom = (target.options.verticalAnchor ?? .bottom) == .bottom
        let flow = page.geometry.canonicalToDisplay(target.canonicalBounds)
        return CGRect(x: flow.minX, y: bottom ? 0 : start.y,
          width: flow.width, height: bottom ? start.y : page.geometry.displaySize.height - start.y)
      }
    }
    return page.geometry.canonicalToDisplay(target.canonicalBounds)
  }

  private func displayedWritingRule(_ target: InkSignPdfTextTarget, page: InkSignPdfPageState) throws -> InkSignPdfPlacementRule? {
    guard let rule = target.canonicalWritingRule else { return nil }
    let start = page.geometry.canonicalToDisplay(rule.start)
    let end = page.geometry.canonicalToDisplay(rule.end)
    guard abs(start.y - end.y) <= 0.001 else { throw TextError.ruleNotFound }
    return InkSignPdfPlacementRule(minX: min(start.x, end.x), maxX: max(start.x, end.x), y: start.y)
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
    documentCoordinator.updateTextPlacement(annotation, page: state.activePage)
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
    documentCoordinator.updateTextPlacement(annotation, page: target)
    if targetIsActive { textInteractionOverlay.syncContent() }
    emitChange()
  }

  func replaceTextAnnotation(_ before: InkSignPdfTextAnnotation,
                             with after: InkSignPdfTextAnnotation,
                             type: InkSignPdfPageContentActionType,
                             generation: UInt64, pageID: UUID) throws {
    guard !disposed, documentCoordinator.generation == generation,
          let page = documentCoordinator.document?.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    guard page.history.replaceText(before: before, with: after, type: type) else { return }
    documentCoordinator.updateTextPlacement(after, page: page)
    if documentCoordinator.document?.activePage.id == pageID { textInteractionOverlay.syncContent() }
    emitChange()
  }

  func removeTextAnnotation(_ annotation: InkSignPdfTextAnnotation,
                            generation: UInt64, pageID: UUID) throws {
    guard !disposed, documentCoordinator.generation == generation,
          let page = documentCoordinator.document?.pages.first(where: { $0.id == pageID }) else {
      throw TextError.cancelled
    }
    guard page.history.removeText(annotation) else { return }
    if documentCoordinator.document?.activePage.id == pageID { textInteractionOverlay.syncContent() }
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
    documentCoordinator.updateTextPlacement(after, page: state.activePage)
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

private extension ResolveTextOptions {
  var annotationOptions: TextAnnotationOptions {
    TextAnnotationOptions(fontSize: fontSize, color: color, direction: direction,
      maxLines: maxLines, alignment: alignment, verticalAnchor: verticalAnchor ?? (fieldName == nil ? .top : .bottom))
  }
}
