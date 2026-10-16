import Foundation
import CoreGraphics

struct InkSignPdfCorePageContext {
  let generation: UInt64
  let pageID: UUID
}

extension DocumentCore {
  func buildEditorAnnotation(id: UInt64, text: String, bounds: CGRect,
    fontSize: CGFloat, textColor: String, isRTL: Bool, flowBounds: CGRect?,
    maxLines: Int, verticalAnchor: InkSignPdfTextVerticalAnchor,
    alignment: InkSignPdfTextAlignment, layoutRotation: Int,
    font: InkSignPdfNamedFont?) -> InkSignPdfTextAnnotation {
    let visible = flowBounds.map {
      InkSignPdfTextRenderer.visibleBounds(for: text, fontSize: fontSize, isRTL: isRTL,
        flowBounds: $0, maxLines: maxLines, verticalAnchor: verticalAnchor, alignment: alignment, font: font)
    } ?? bounds
    return InkSignPdfTextAnnotation(id: id, text: text, bounds: visible,
      fontSize: fontSize, textColor: textColor, isRTL: isRTL, flowBounds: flowBounds,
      maxLines: maxLines, verticalAnchor: verticalAnchor, alignment: alignment,
      layoutRotation: layoutRotation, font: font)
  }
  func inputTarget(_ context: InkSignPdfCorePageContext, id: Double) throws -> InputTarget {
    let (page, target) = try self.target(context, id: id)
    let annotation = page.history.text(for: target.id)
    let edit = activeTextEdit.flatMap { $0.page.id == page.id && $0.id == target.id ? $0 : nil }
    let bounds = displayedTargetBounds(target, page: page)
    return InputTarget(id: Double(target.id), value: edit.map { $0.current?.text ?? "" } ?? annotation?.text ?? target.embeddedValue,
      fieldName: target.fieldName,
      bounds: TextAnnotationBounds(x: Double(bounds.minX), y: Double(bounds.minY),
        width: Double(bounds.width), height: Double(bounds.height)),
      valueSource: edit != nil || annotation != nil ? .annotation : target.embeddedValue.isEmpty ? .empty : .embedded)
  }

  func inputTargets(_ context: InkSignPdfCorePageContext) throws -> [InputTarget] {
    _ = try page(context)
    return try coordinator.textTargets(for: context.pageID).map { try inputTarget(context, id: Double($0.id)) }
  }

  func adjustTextSize(_ context: InkSignPdfCorePageContext, id: Double, delta: Double) throws -> Double {
    let (page, target) = try self.target(context, id: id)
    let current = page.history.text(for: target.id)
    let size = current.map { Double($0.fontSize) } ?? target.options.fontSize ?? defaultTextFontSize
    guard delta.isFinite else { throw TextError.invalidBounds }
    let next = min(max(size + delta, 8), 72)
    try setTextOptions(context, id: id, options: TextAnnotationOptions(untracked: nil,
      font: nil, fontSize: next, color: nil, direction: nil, maxLines: nil, alignment: nil, verticalAnchor: nil))
    return next
  }

  func target(_ context: InkSignPdfCorePageContext, id: Double) throws -> (InkSignPdfPageState, InkSignPdfTextTarget) {
    let page = try self.page(context)
    guard id.isFinite, id >= 1, id.rounded(.towardZero) == id, id <= 9_007_199_254_740_991 else {
      throw TextError.textNotFound
    }
    return (page, try coordinator.textTarget(UInt64(id), pageID: page.id))
  }

  func textValue(_ context: InkSignPdfCorePageContext, id: Double) throws -> String {
    let (page, target) = try self.target(context, id: id)
    if let edit = activeTextEdit, edit.page.id == page.id, edit.id == target.id {
      return edit.current?.text ?? ""
    }
    return page.history.text(for: target.id)?.text ?? target.embeddedValue
  }

  func setTextValue(_ context: InkSignPdfCorePageContext, id: Double, text: String,
                    options: TextAnnotationOptions? = nil) throws {
    try requireContentMutationReady()
    guard text.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TextError.invalidText
    }
    let (page, target) = try self.target(context, id: id)
    let proposed = try updatedTextOptions(target.options, changes: options)
    let current = page.history.text(for: target.id)
    let updated: InkSignPdfTextAnnotation?
    if text.isEmpty {
      updated = nil
    } else if let current {
      let size = PageGeometry(mediaBox: page.geometry.visibleBox, rotation: current.layoutRotation).displaySize
      let styled = InkSignPdfTextAnnotation(id: current.id, text: text, bounds: current.bounds,
        fontSize: CGFloat(options?.fontSize ?? Double(current.fontSize)),
        textColor: options?.color ?? current.textColor,
        isRTL: options?.direction.map { resolvedDirection($0) } ?? current.isRTL,
        flowBounds: current.flowBounds, maxLines: options?.maxLines == nil ? current.maxLines : proposed.maxLines!,
        verticalAnchor: options?.verticalAnchor.map(InkSignPdfTextVerticalAnchor.init) ?? current.verticalAnchor,
        alignment: options?.alignment.map(InkSignPdfTextAlignment.init) ?? current.alignment,
        layoutRotation: current.layoutRotation,
        font: options?.font == nil ? current.font : proposed.font)
      updated = styled.replacingText(text, pageSize: size)
    } else {
      _ = try displayedWritingRule(target, page: page)
      let flow = displayedTargetBounds(target, page: page)
      let size = CGFloat(proposed.fontSize ?? defaultTextFontSize)
      let rtl = resolvedDirection(proposed.direction)
      let anchor = InkSignPdfTextVerticalAnchor(proposed.verticalAnchor)
      let alignment = InkSignPdfTextAlignment(proposed.alignment)
      let lines = proposed.maxLines ?? 0
      updated = InkSignPdfTextAnnotation(id: target.id, text: text,
        bounds: InkSignPdfTextRenderer.visibleBounds(for: text, fontSize: size, isRTL: rtl,
          flowBounds: flow, maxLines: lines, verticalAnchor: anchor, alignment: alignment, font: proposed.font),
        fontSize: size, textColor: proposed.color ?? defaultTextColor, isRTL: rtl,
        flowBounds: flow, maxLines: lines, verticalAnchor: anchor, alignment: alignment,
        layoutRotation: page.geometry.rotation, font: proposed.font)
    }
    endTextEdit(id: target.id)
    try coordinator.updateTextTarget(target.id, pageID: page.id) { $0.options = proposed }
    let untracked = options?.untracked == true
    let edited: Bool
    if let current {
      if let updated {
        edited = page.history.replaceText(before: current, with: updated, type: .textEdit, untracked: untracked)
      } else { edited = page.history.removeText(current, untracked: untracked) }
    } else {
      edited = updated.map { page.history.appendText($0, untracked: untracked) } ?? false
    }
    if edited {
      if let annotation = page.history.text(for: target.id) {
        coordinator.updateTextPlacement(annotation, page: page)
      }
      changed(.page(page.id))
    }
  }

  func setTextOptions(_ context: InkSignPdfCorePageContext, id: Double,
                      options: TextAnnotationOptions, applyToCommitted: Bool = true,
                      endEditing: Bool = true) throws {
    try requireContentMutationReady()
    let (page, target) = try self.target(context, id: id)
    let proposed = try updatedTextOptions(target.options, changes: options)
    let current = applyToCommitted ? page.history.text(for: target.id) : nil
    let updated = current.map { current in
      let size = CGFloat(options.fontSize ?? Double(current.fontSize))
      let styled = InkSignPdfTextAnnotation(id: current.id, text: current.text, bounds: current.bounds,
        fontSize: size, textColor: options.color ?? current.textColor,
        isRTL: options.direction.map { resolvedDirection($0) } ?? current.isRTL,
        flowBounds: current.flowBounds, maxLines: options.maxLines == nil ? current.maxLines : proposed.maxLines!,
        verticalAnchor: options.verticalAnchor.map(InkSignPdfTextVerticalAnchor.init) ?? current.verticalAnchor,
        alignment: options.alignment.map(InkSignPdfTextAlignment.init) ?? current.alignment,
        layoutRotation: current.layoutRotation, font: options.font == nil ? current.font : proposed.font)
      return styled.replacingText(styled.text,
        pageSize: PageGeometry(mediaBox: page.geometry.visibleBox, rotation: current.layoutRotation).displaySize)
    }
    if endEditing { endTextEdit(id: target.id) }
    try coordinator.updateTextTarget(target.id, pageID: page.id) { $0.options = proposed }
    guard let current, let updated else { return }
    if page.history.replaceText(before: current, with: updated, type: .textEdit,
                                untracked: options.untracked == true) {
      coordinator.updateTextPlacement(updated, page: page)
      changed(.page(page.id))
    }
  }

  private func updatedTextOptions(_ previous: InkSignPdfTextTargetOptions,
                                  changes: TextAnnotationOptions?) throws -> InkSignPdfTextTargetOptions {
    guard let changes else { return previous }
    var proposed = previous
    proposed.font = try fonts.resolve(changes.font, previous: previous.font)
    if let selection = changes.font {
      if case .second(let name) = selection { proposed.fontName = name }
      else { proposed.fontName = nil }
    }
    if let value = changes.fontSize { proposed.fontSize = value }
    if let value = changes.color { proposed.color = value }
    if let value = changes.direction { proposed.direction = value }
    if let value = changes.maxLines { proposed.maxLines = try InkSignPdfTextTargetOptions.lineLimit(value) }
    if let value = changes.alignment { proposed.alignment = value }
    if let value = changes.verticalAnchor { proposed.verticalAnchor = value }
    return proposed
  }
  func page(_ context: InkSignPdfCorePageContext) throws -> InkSignPdfPageState {
    try requireClientAccess()
    guard coordinator.generation == context.generation,
          let page = coordinator.document?.pages.first(where: { $0.id == context.pageID }) else {
      throw TextError.cancelled
    }
    return page
  }

  func resolvedDirection(_ direction: TextDirection?) -> Bool {
    switch direction {
    case .ltr?: return false
    case .rtl?: return true
    case .auto?: return appDirectionRTL
    case nil: return appDirectionRTL
    }
  }

  func resolveText(_ context: InkSignPdfCorePageContext, options: InputTargetResolutionOptions) throws -> Double {
    try requireContentMutationReady()
    let selectedFont = try fonts.resolveSelection(options.font)
    let page = try self.page(context)
    let geometry = page.geometry
    let fieldBounds: CGRect
    var identity: String?
    var embeddedValue = ""
    var selectedRule: InkSignPdfCanonicalWritingRule?
    var excludedSourceRanges: [NSRange] = []
    var detectionBounds: CGRect
    if let fieldName = options.fieldName {
      let lookup = page.sourceAnalysis.lookup(key: fieldName)
      guard lookup.hasLiteralMatch else { throw TextError.keyNotFound }
      let projected = page.prepared.projected(geometry: geometry)
      let displayed = projected.geometry
      let region = options.bounds
      guard let placement = projected.selectPair(lookup: lookup, region: region,
        occurrence: options.occurrence == .last ? .last : .first,
        rtl: resolvedDirection(options.direction?.boundaryValue)) else { throw TextError.ruleNotFound }
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
      guard let label = page.sourceAnalysis.labelCandidates.first(where: { $0.match.sourceIndex == placement.match.sourceIndex }) else {
        preconditionFailure("Selected label is missing from its prepared analysis")
      }
      identity = "\(label.identity)|\(sourceRule.sourceIndex)"
      excludedSourceRanges = label.sourceRanges
      detectionBounds = CGRect(x: placement.rule.minX,
        y: anchor == .bottom ? placement.rule.y - placement.match.lineHeight : placement.rule.y,
        width: placement.rule.maxX - placement.rule.minX, height: placement.match.lineHeight)
    } else {
      guard let bounds = options.bounds else { throw TextError.invalidBounds }
      fieldBounds = bounds
      guard validPreparedBounds(fieldBounds, pageSize: geometry.displaySize) else { throw TextError.invalidBounds }
      detectionBounds = fieldBounds
    }
    let canonicalBounds = geometry.displayToCanonical(fieldBounds)
    let canonicalDetectionBounds = geometry.displayToCanonical(detectionBounds)
    embeddedValue = page.sourceAnalysis.embeddedText(in: canonicalDetectionBounds, excluding: excludedSourceRanges)
    let occupied = page.history.content.textAnnotations.filter {
      let bounds = $0.bounds.applying(geometry.layoutToDisplay(rotation: $0.layoutRotation))
      return bounds.minX < detectionBounds.maxX && bounds.maxX > detectionBounds.minX &&
        bounds.minY < detectionBounds.maxY && bounds.maxY > detectionBounds.minY
    }
    guard occupied.count <= 1 else { throw TextError.targetAmbiguous }
    let target: InkSignPdfTextTarget
    if let existing = coordinator.findTextTarget(pageID: page.id, sourceIdentity: identity,
                                                         canonicalBounds: canonicalBounds) { return Double(existing.id) }
    if let annotation = occupied.first {
      target = try coordinator.adoptTextTarget(id: annotation.id, pageID: page.id,
        sourceIdentity: identity, fieldName: options.fieldName, canonicalBounds: canonicalBounds,
        embeddedValue: embeddedValue, canonicalWritingRule: selectedRule,
        canonicalDetectionBounds: canonicalDetectionBounds, excludedSourceRanges: excludedSourceRanges)
    } else {
      target = try coordinator.reserveTextTarget(pageID: page.id, sourceIdentity: identity,
        fieldName: options.fieldName, canonicalBounds: canonicalBounds, options: options.annotationOptions,
        embeddedValue: embeddedValue, canonicalWritingRule: selectedRule,
        canonicalDetectionBounds: canonicalDetectionBounds, excludedSourceRanges: excludedSourceRanges)
      try coordinator.updateTextTarget(target.id, pageID: page.id) { $0.options.font = selectedFont }
    }
    return Double(target.id)
  }

  func validPreparedBounds(_ bounds: CGRect, pageSize: CGSize) -> Bool {
    bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
      bounds.width > 0 && bounds.height > 0 && bounds.minX >= 0 && bounds.minY >= 0 &&
      bounds.maxX <= pageSize.width && bounds.maxY <= pageSize.height
  }

  func displayedTargetBounds(_ target: InkSignPdfTextTarget, page: InkSignPdfPageState) -> CGRect {
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

  func displayedWritingRule(_ target: InkSignPdfTextTarget, page: InkSignPdfPageState) throws -> InkSignPdfPlacementRule? {
    guard let rule = target.canonicalWritingRule else { return nil }
    let start = page.geometry.canonicalToDisplay(rule.start)
    let end = page.geometry.canonicalToDisplay(rule.end)
    guard abs(start.y - end.y) <= 0.001 else { throw TextError.ruleNotFound }
    return InkSignPdfPlacementRule(minX: min(start.x, end.x), maxX: max(start.x, end.x), y: start.y)
  }

}
