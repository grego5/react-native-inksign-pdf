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
  func allocateTextAnnotationID() throws -> UInt64 {
    try documentCoordinator.allocateTextID()
  }

  func setTextMode(options: TextModeOptions?) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      try self.requireViewportReady(request: .preserve)
      self.fieldFocusRequestID &+= 1
      self.textInteractionOverlay.finishForLifecycle()
      self.setInteractionMode(editing: false)
      try self.textInteractionOverlay.armPlacement(generation: self.documentCoordinator.generation,
                                                  options: options)
    }
  }

  func setTextDirection(direction: TextDirection) throws {
    try performOnMainSync {
      guard !self.disposed else { throw TextError.cancelled }
      self.textInteractionOverlay.setTextDirection(direction: direction)
    }
  }

  func getPage(pageIndex: Double?) throws -> Promise<any HybridAnalyzedPageSpec> {
    let captured = try performOnMainSync { () throws -> (URL, UInt64, Int, UUID, CGRect) in
      guard !self.disposed else { throw TextError.cancelled }
      guard let document = self.documentCoordinator.document else { throw TextError.documentNotOpen }
      let index: Int
      if let pageIndex {
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
          settlement.resolve(HybridAnalyzedPage(owner: self, generation: captured.1,
            pageID: captured.3, analysis: try result.get()))
        } catch {
          settlement.reject(error)
        }
      }
    }
    return settlement.promise
  }

  func resolvePreparedText(_ handle: HybridAnalyzedPage, options: ResolveTextOptions) throws -> Double {
    try validatePreparedHandle(handle)
    guard let document = documentCoordinator.document,
          let page = document.pages.first(where: { $0.id == handle.pageID }) else { throw TextError.cancelled }
    let geometry = page.geometry
    let fieldBounds: CGRect
    var identity: String?
    var embeddedValue = ""
    var selectedRule: InkSignPdfPlacementRule?
    var detectionBounds: CGRect
    if let fieldName = options.fieldName {
      let lookup = handle.analysis.lookup(key: fieldName)
      guard lookup.hasLiteralMatch else { throw TextError.keyNotFound }
      let displayed = handle.analysis.displayedFieldGeometry(lookup: lookup,
        sourceGeometry: page.sourceGeometry, geometry: geometry)
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
      selectedRule = placement.rule
      guard let ruleIndex = displayed.rules.firstIndex(of: placement.rule) else { throw TextError.ruleNotFound }
      let sourceRule = handle.analysis.rules[ruleIndex]
      identity = "\(placement.match.sourceIndex)|\(sourceRule.minX):\(sourceRule.maxX):\(sourceRule.y)"
      detectionBounds = CGRect(x: placement.rule.minX,
        y: anchor == .bottom ? placement.rule.y - placement.match.lineHeight : placement.rule.y,
        width: placement.rule.maxX - placement.rule.minX, height: placement.match.lineHeight)
      embeddedValue = embeddedText(in: detectionBounds, analysis: handle.analysis,
        sourceGeometry: page.sourceGeometry, geometry: geometry,
        excluded: handle.analysis.labelCandidates.first { $0.match.sourceIndex == placement.match.sourceIndex }?.sourceRanges ?? [])
    } else {
      guard let bounds = options.bounds else { throw TextError.invalidBounds }
      fieldBounds = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
      guard validPreparedBounds(fieldBounds, pageSize: geometry.displaySize) else { throw TextError.invalidBounds }
      detectionBounds = fieldBounds
      embeddedValue = embeddedText(in: detectionBounds, analysis: handle.analysis,
        sourceGeometry: page.sourceGeometry, geometry: geometry)
    }
    let occupied = page.history.content.textAnnotations.filter {
      let basis = PageGeometry(mediaBox: page.geometry.mediaBox, rotation: $0.layoutRotation)
      return geometry.rawToDisplay(basis.displayToRaw($0.bounds)).intersects(detectionBounds)
    }
    guard occupied.count <= 1 else { throw TextError.targetAmbiguous }
    let target: InkSignPdfTextTarget
    if let existing = documentCoordinator.textTargets(for: page.id).first(where: {
      if let identity { return $0.sourceIdentity == identity }
      return $0.sourceIdentity == nil && displayedTargetBounds($0, page: page) == fieldBounds
    }) { return Double(existing.id) }
    if let annotation = occupied.first {
      target = try documentCoordinator.adoptTextTarget(id: annotation.id, pageID: page.id,
        sourceIdentity: identity, fieldName: options.fieldName, bounds: fieldBounds,
        options: options.annotationOptions, embeddedValue: embeddedValue)
    } else {
      target = try documentCoordinator.reserveTextTarget(pageID: page.id, sourceIdentity: identity,
        fieldName: options.fieldName, bounds: fieldBounds, options: options.annotationOptions,
        embeddedValue: embeddedValue)
    }
    try documentCoordinator.updateTextTarget(target.id, pageID: page.id) {
      $0.layoutGeometry = geometry
      $0.writingRule = selectedRule
    }
    return Double(target.id)
  }

  func preparedTextValue(_ handle: HybridAnalyzedPage, id: Double) throws -> String {
    let (page, target) = try preparedTarget(handle, id: id)
    return textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
      ?? page.history.content.textAnnotations.first(where: { $0.id == target.id })?.text
      ?? target.embeddedValue
  }

  func setPreparedTextValue(_ handle: HybridAnalyzedPage, id: Double, text: String) throws {
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
          page.geometry.displaySize, page.geometry.rotation), coordinateSpace: .displayed,
        targetID: target.id)
    }
  }

  func clearPreparedText(_ handle: HybridAnalyzedPage, id: Double) throws {
    let (page, target) = try preparedTarget(handle, id: id)
    textInteractionOverlay.clearPreparedDraft(id: target.id, pageID: page.id)
    if let current = page.history.content.textAnnotations.first(where: { $0.id == target.id }) {
      try removeTextAnnotation(current, generation: handle.generation, pageID: page.id)
    }
  }

  func setPreparedTextOptions(_ handle: HybridAnalyzedPage, id: Double,
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
    let styled = current.changingFontSize(to: fontSize, pageSize: PageGeometry(mediaBox: page.geometry.mediaBox, rotation: current.layoutRotation).displaySize)
    let updated = InkSignPdfTextAnnotation(id: styled.id, text: styled.text, bounds: styled.bounds,
      fontSize: styled.fontSize, textColor: options.color ?? current.textColor,
      isRTL: options.direction.map { textInteractionOverlay.resolvedDirection($0) } ?? current.isRTL,
      flowBounds: styled.flowBounds, maxLines: Int(options.maxLines ?? Double(current.maxLines)),
      verticalAnchor: options.verticalAnchor.map(InkSignPdfTextVerticalAnchor.init) ?? current.verticalAnchor,
      alignment: options.alignment.map(InkSignPdfTextAlignment.init) ?? current.alignment,
      layoutRotation: current.layoutRotation)
    if updated != current {
      try replaceTextAnnotation(current, with: updated, type: .textEdit,
                                generation: handle.generation, pageID: page.id)
    }
  }

  func preparedTextEntry(_ handle: HybridAnalyzedPage, id: Double) throws -> TextEntry {
    let (page, target) = try preparedTarget(handle, id: id)
    let draft = textInteractionOverlay.preparedDraftText(id: target.id, pageID: page.id)
    let annotation = page.history.content.textAnnotations.first(where: { $0.id == target.id })
    let value = draft ?? annotation?.text ?? target.embeddedValue
    let source: TextValueSource = draft != nil || annotation != nil ? .annotation
      : (!target.embeddedValue.isEmpty ? .embedded : .empty)
    return TextEntry(id: Double(target.id), value: value, fieldName: target.fieldName,
      bounds: displayedTargetBounds(target, page: page).publicBounds, hasValue: !value.isEmpty, valueSource: source)
  }

  func adjustPreparedTextSize(_ handle: HybridAnalyzedPage, id: Double, delta: Double) throws -> Double {
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

  func preparedTextEntries(_ handle: HybridAnalyzedPage) throws -> [TextEntry] {
    try validatePreparedHandle(handle)
    return try documentCoordinator.textTargets(for: handle.pageID).map {
      try preparedTextEntry(handle, id: Double($0.id))
    }
  }

  func focusPreparedText(_ handle: HybridAnalyzedPage, id: Double,
                         options: FieldFocusOptions?) throws -> Promise<Void> {
    let (page, target) = try preparedTarget(handle, id: id)
    let rule = try displayedWritingRule(target, page: page)
    let bounds = displayedTargetBounds(target, page: page)
    let result = InkSignPdfOperationPromise<Void>()
    performOnMain {
      guard !self.disposed, self.documentCoordinator.generation == handle.generation else {
        result.reject(TextError.cancelled); return
      }
      guard let document = self.documentCoordinator.document,
            let index = document.index(of: handle.pageID) else { result.reject(TextError.cancelled); return }
      self.fieldFocusRequestID &+= 1
      let requestID = self.fieldFocusRequestID
      let runFocus = {
        guard !self.disposed, self.fieldFocusRequestID == requestID,
              self.documentCoordinator.document?.activePage.id == handle.pageID else {
          result.reject(TextError.cancelled); return
        }
        self.textInteractionOverlay.finishForLifecycle()
        guard let viewportTarget = self.fieldFocusTarget(ruleY: rule?.y ?? bounds.midY,
          horizontalFocus: rule.map { ($0.minX + $0.maxX) / 2 } ?? bounds.midX, zoom: options?.zoom ?? 2,
          verticalAnchor: options?.verticalAnchor ?? .center, edgeOffset: options?.edgeOffset ?? 0),
          self.applyViewport(target: viewportTarget) else { result.reject(TextError.notReady); return }
        if options?.setInkMode == true { self.setInteractionMode(editing: true) }
        result.resolve(())
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

  private func validatePreparedHandle(_ handle: HybridAnalyzedPage) throws {
    guard !disposed, documentCoordinator.generation == handle.generation,
          documentCoordinator.document?.pages.contains(where: { $0.id == handle.pageID }) == true else {
      throw TextError.cancelled
    }
  }

  private func preparedTarget(_ handle: HybridAnalyzedPage, id: Double) throws -> (InkSignPdfPageState, InkSignPdfTextTarget) {
    try validatePreparedHandle(handle)
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
    guard let basis = target.layoutGeometry else { return target.bounds }
    if let rule = target.writingRule {
      let start = page.geometry.rawToDisplay(basis.displayToRaw(CGPoint(x: rule.minX, y: rule.y)))
      let end = page.geometry.rawToDisplay(basis.displayToRaw(CGPoint(x: rule.maxX, y: rule.y)))
      if abs(start.y - end.y) <= 0.001 {
        let bottom = (target.options.verticalAnchor ?? .bottom) == .bottom
        let flow = page.geometry.rawToDisplay(basis.displayToRaw(target.bounds))
        return CGRect(x: flow.minX, y: bottom ? 0 : start.y,
          width: flow.width, height: bottom ? start.y : page.geometry.displaySize.height - start.y)
      }
    }
    return page.geometry.rawToDisplay(basis.displayToRaw(target.bounds))
  }

  private func displayedWritingRule(_ target: InkSignPdfTextTarget, page: InkSignPdfPageState) throws -> InkSignPdfPlacementRule? {
    guard let rule = target.writingRule, let basis = target.layoutGeometry else { return nil }
    let start = page.geometry.rawToDisplay(basis.displayToRaw(CGPoint(x: rule.minX, y: rule.y)))
    let end = page.geometry.rawToDisplay(basis.displayToRaw(CGPoint(x: rule.maxX, y: rule.y)))
    guard abs(start.y - end.y) <= 0.001 else { throw TextError.ruleNotFound }
    return InkSignPdfPlacementRule(minX: min(start.x, end.x), maxX: max(start.x, end.x), y: start.y)
  }

  private func embeddedText(in bounds: CGRect, analysis: InkSignPdfPageAnalysis,
                            sourceGeometry: PageGeometry, geometry: PageGeometry, excluded ranges: [NSRange] = []) -> String {
    let source = analysis.sourceText as NSString
    let excluded = ranges.reduce(into: Set<Int>()) { result, range in
      for index in range.location..<(range.location + range.length) { result.insert(index) }
    }
    var included = [Bool](repeating: false, count: source.length)
    for index in 0..<min(source.length, min(analysis.characterBounds.count, analysis.characterVisualRows.count)) {
      guard !excluded.contains(index), let rect = analysis.characterBounds[index] else { continue }
      let sourceDisplay = CGRect(x: rect.minX * sourceGeometry.displaySize.width / analysis.pageSize.width,
                                 y: rect.minY * sourceGeometry.displaySize.height / analysis.pageSize.height,
                                 width: rect.width * sourceGeometry.displaySize.width / analysis.pageSize.width,
                                 height: rect.height * sourceGeometry.displaySize.height / analysis.pageSize.height)
      let projected = geometry.rawToDisplay(sourceGeometry.displayToRaw(sourceDisplay))
      guard bounds.intersects(projected) else { continue }
      included[index] = true
    }
    if source.length > 0 {
      for index in 0..<source.length where !excluded.contains(index) && Self.isWhitespace(source.character(at: index)) {
        let before = (0..<index).reversed().first { included[$0] }
        let after = ((index + 1)..<source.length).first { included[$0] }
        if let before, let after, analysis.characterVisualRows[before] == analysis.characterVisualRows[after] {
          included[index] = true
        }
      }
    }
    var ranges: [NSRange] = []
    var start: Int?
    for index in 0...source.length {
      let selected = index < source.length && included[index]
      if selected, start == nil { start = index }
      if !selected, let rangeStart = start {
        ranges.append(NSRange(location: rangeStart, length: index - rangeStart))
        start = nil
      }
    }
    return ranges.map { source.substring(with: $0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isWhitespace(_ value: unichar) -> Bool {
    value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D || value == 0x00A0
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
    if (try? documentCoordinator.textTarget(annotation.id, pageID: state.activePage.id)) == nil {
      _ = try? documentCoordinator.adoptTextTarget(id: annotation.id, pageID: state.activePage.id,
        sourceIdentity: nil, fieldName: nil, bounds: annotation.flowBounds ?? annotation.bounds,
        options: nil, embeddedValue: "")
    }
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
    if (try? documentCoordinator.textTarget(annotation.id, pageID: pageID)) == nil {
      _ = try documentCoordinator.adoptTextTarget(id: annotation.id, pageID: pageID,
        sourceIdentity: nil, fieldName: nil, bounds: annotation.flowBounds ?? annotation.bounds,
        options: nil, embeddedValue: "")
    }
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
      maxLines: maxLines, alignment: alignment, verticalAnchor: verticalAnchor)
  }
}
