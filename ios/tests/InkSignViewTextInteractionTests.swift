import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewTextInteractionTests: XCTestCase, InkSignViewTestSupport {
  private func cachePlacementRules(_ rules: [InkSignPdfPlacementRule],
                                  overlay: InkSignPdfTextInteractionOverlay,
                                  generation: UInt64,
                                  pageID: UUID) throws {
    let requestID = try XCTUnwrap(overlay.beginPlacementRuleScan(generation: generation,
                                                                 pageID: pageID))
    overlay.installPlacementRules(rules,
                                  generation: generation,
                                  pageID: pageID,
                                  requestID: requestID)
  }

  func testKeyboardLanguageUsesLocaleCharacterDirection() {
    XCTAssertEqual(InkSignPdfTextDirectionState.writingDirectionHint(for: "he-IL"), true)
    XCTAssertEqual(InkSignPdfTextDirectionState.writingDirectionHint(for: "ps-AF"), true)
    XCTAssertEqual(InkSignPdfTextDirectionState.writingDirectionHint(for: "en-US"), false)
    XCTAssertNil(InkSignPdfTextDirectionState.writingDirectionHint(for: nil))
  }

  func testAutomaticTextDirectionFollowsKeyboardOnlyWhileTheNewEditorIsEmpty() {
    var direction = InkSignPdfTextDirectionState(request: .automatic, fallbackRTL: false)

    XCTAssertTrue(direction.adoptInputDirectionWhileEmpty(true))
    XCTAssertTrue(direction.effectiveRTL)
    XCTAssertFalse(direction.lockForContent(hasStrongRTL: false))
    XCTAssertTrue(direction.effectiveRTL)
    XCTAssertTrue(direction.isLocked)
    XCTAssertFalse(direction.adoptInputDirectionWhileEmpty(true))
    XCTAssertTrue(direction.effectiveRTL)

    XCTAssertTrue(direction.reopenEmptyEditor(false))
    XCTAssertFalse(direction.effectiveRTL)
    XCTAssertFalse(direction.isLocked)
    XCTAssertFalse(direction.lockForContent(hasStrongRTL: false))
    XCTAssertTrue(direction.lockForContent(hasStrongRTL: true))
    XCTAssertTrue(direction.isLocked)
    XCTAssertTrue(direction.effectiveRTL)
    XCTAssertTrue(direction.lockForContent(hasStrongRTL: false))
    XCTAssertFalse(direction.effectiveRTL,
                   "Removing RTL content restores the direction adopted while empty")
    XCTAssertFalse(direction.reopenEmptyEditor(false))
    XCTAssertFalse(direction.effectiveRTL)
  }

  func testExplicitAndReopenedTextDirectionsIgnoreKeyboardLanguage() {
    var explicitLTR = InkSignPdfTextDirectionState(request: .fixed(false), fallbackRTL: true)
    XCTAssertFalse(explicitLTR.adoptInputDirectionWhileEmpty(true))
    XCTAssertFalse(explicitLTR.lockForContent(hasStrongRTL: true))
    XCTAssertFalse(explicitLTR.effectiveRTL)

    var reopenedRTL = InkSignPdfTextDirectionState(request: .fixed(true), fallbackRTL: false)
    XCTAssertFalse(reopenedRTL.adoptInputDirectionWhileEmpty(false))
    XCTAssertFalse(reopenedRTL.reopenEmptyEditor(false))
    XCTAssertTrue(reopenedRTL.effectiveRTL)
    XCTAssertTrue(reopenedRTL.isLocked)
  }

  func testReopeningCommittedAnnotationUsesItsSavedDirection() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let annotation = makeCenteredTextAnnotation(id: "rtl-text", text: "שלום",
                                                 fontSize: 16,
                                                 pageSize: fixture.view.activePageSize(),
                                                 isRTL: true)
    fixture.view.appendTextAnnotation(annotation,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)

    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: annotation.bounds.midX,
                                                y: annotation.bounds.midY)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)

    overlay.finishForLifecycle()
    let reopened = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history
      .content.textAnnotations.first)
    XCTAssertTrue(reopened.isRTL)
  }

  func testShortTextUsesItsLaidOutWidthInBothDirections() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    for (direction, value) in [(TextDirection.ltr, "text"), (.rtl, "שלום")] {
      overlay.setTextDirection(direction)
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
      XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      editor.text = value
      overlay.textViewDidChange(editor)

      let contentWidth = editor.bounds.width - editor.textContainerInset.left -
        editor.textContainerInset.right
      XCTAssertLessThan(contentWidth, fixture.view.activePageSize().width / 2)
      overlay.finishForLifecycle()
    }
  }

  func testTextBoxGeometryCentersTouchAndPreservesSelectedBottomEdge() {
    let insets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
    let pageSize = CGSize(width: 200, height: 100)
    let anchor = InkSignPdfTextBoxGeometry.PlacementAnchor(centerX: 80,
                                                           bottomY: 50,
                                                           bottomEdge: .innerTextArea)

    let compact = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                         size: CGSize(width: 40, height: 28),
                                                         insets: insets,
                                                         pageSize: pageSize)
    XCTAssertEqual(compact, CGRect(x: 60, y: 28, width: 40, height: 28))
    XCTAssertEqual(compact.midX, anchor.centerX)
    XCTAssertEqual(compact.maxY - insets.bottom, anchor.bottomY)

    let expanded = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                          size: CGSize(width: 72, height: 44),
                                                          insets: insets,
                                                          pageSize: pageSize)
    XCTAssertEqual(expanded.midX, anchor.centerX)
    XCTAssertEqual(expanded.maxY - insets.bottom, anchor.bottomY)

    let snapped = InkSignPdfTextBoxGeometry.initialFrame(
      anchor: .init(centerX: 80, bottomY: 50, bottomEdge: .outerBox),
      size: CGSize(width: 40, height: 28), insets: insets, pageSize: pageSize)
    XCTAssertEqual(snapped, CGRect(x: 60, y: 22, width: 40, height: 28))
    XCTAssertEqual(snapped.maxY, 50)

    let edge = InkSignPdfTextBoxGeometry.initialFrame(
      anchor: .init(centerX: 0, bottomY: 0, bottomEdge: .innerTextArea),
      size: CGSize(width: 40, height: 28), insets: insets, pageSize: pageSize)
    XCTAssertEqual(edge.origin, .zero)
  }

  func testInitialPlacementIsCenteredForLTRRTLAndAutomaticDirection() throws {
    let tap = CGPoint(x: 150, y: 140)
    var frames: [CGRect] = []
    let directions: [Bool?] = [nil, false, true]
    for direction in directions {
      let fixture = makeFixture(pageCount: 1)
      let overlay = fixture.view.textInteractionOverlay
      overlay.setTextDirection(isRTL: direction)
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
      XCTAssertTrue(overlay.routePlacementTap(at: tap))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      frames.append(editor.frame)
      XCTAssertEqual(editor.frame.midX, tap.x, accuracy: 0.001)
      XCTAssertEqual(editor.frame.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                     tap.y,
                     accuracy: 0.001)
      fixture.view.dispose()
      fixture.window.isHidden = true
    }
    XCTAssertEqual(frames[0].origin, frames[1].origin)
    XCTAssertEqual(frames[1].origin, frames[2].origin)
  }

  func testSnappedPlacementUsesRuleBeforeDisplayAndKeepsOuterBottomDuringGrowth() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)
    try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.midX, 150, accuracy: 0.001)
    XCTAssertEqual(editor.frame.maxY, rule.y, accuracy: 0.001)
    editor.text = "A note that grows above the selected rule while it is edited"
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    overlay.textViewDidChange(editor)
    XCTAssertGreaterThan(editor.frame.height, 16)
    XCTAssertEqual(editor.frame.maxY, rule.y, accuracy: 0.001)
    XCTAssertEqual(editor.frame.midX, 150, accuracy: 0.001)
  }

  func testRuleSnapUsesTheSameScreenDistanceAtDifferentZoomLevels() throws {
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)

    func placementIsSnapped(zoom: CGFloat, screenDistance: CGFloat) throws -> Bool {
      let fixture = makeFixture(pageCount: 1)
      defer { fixture.view.dispose(); fixture.window.isHidden = true }
      let overlay = fixture.view.textInteractionOverlay
      let generation = fixture.view.documentCoordinator.generation
      let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
      let transform = CGAffineTransform(scaleX: zoom, y: zoom)
      fixture.view.pageToOverlayTransform = transform
      try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
      try overlay.armPlacement(generation: generation)

      let point = CGPoint(x: 80 * zoom, y: rule.y * zoom - screenDistance)
      XCTAssertTrue(overlay.routePlacementTap(at: point))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      return abs(editor.frame.maxY - rule.y * zoom) < 0.001
    }

    for screenDistance in [CGFloat(20), 28] {
      let atOneX = try placementIsSnapped(zoom: 1, screenDistance: screenDistance)
      let atTwoX = try placementIsSnapped(zoom: 2, screenDistance: screenDistance)
      XCTAssertEqual(atOneX, atTwoX, "A \(screenDistance)-point gap must have the same snap decision at 1x and 2x")
      XCTAssertEqual(atOneX, screenDistance <= 24,
                     "Only rules within the fixed 24-point screen-space tolerance should snap")
    }
  }

  func testRuleWithoutRoomForInitialBoxFallsBackToTapPlacement() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 20)
    let tap = CGPoint(x: 150, y: 40)
    try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: tap))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.midX, tap.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                   tap.y,
                   accuracy: 0.001)
    XCTAssertNotEqual(editor.frame.maxY, rule.y)
  }

  func testEmptyPlacementRuleResultLeavesOrdinaryPlacementAvailable() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
    try cachePlacementRules([], overlay: overlay, generation: generation, pageID: pageID)
    let tap = CGPoint(x: 150, y: 140)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: tap))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.midX, tap.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                   tap.y,
                   accuracy: 0.001)
  }

  func testPlacementUsesOrdinaryFallbackUntilCurrentScanCompletesAndReusesResults() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
    let nearbyRule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)

    let obsoleteRequestID = try XCTUnwrap(overlay.beginPlacementRuleScan(
      generation: generation, pageID: pageID))
    overlay.clearPlacementRules()
    let activeRequestID = try XCTUnwrap(overlay.beginPlacementRuleScan(
      generation: generation, pageID: pageID))
    overlay.installPlacementRules([nearbyRule],
                                  generation: generation,
                                  pageID: pageID,
                                  requestID: obsoleteRequestID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))
    var editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                   195,
                   accuracy: 0.001)
    overlay.finishForLifecycle()

    overlay.installPlacementRules([nearbyRule],
                                  generation: generation,
                                  pageID: pageID,
                                  requestID: activeRequestID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))
    editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.maxY, nearbyRule.y, accuracy: 0.001)
  }

  func testPlacementRuleCacheIsPageLocalAndRejectsPreviousPageResults() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let firstPageID = fixture.pages[0]
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)
    let firstRequestID = try XCTUnwrap(overlay.beginPlacementRuleScan(
      generation: generation, pageID: firstPageID))
    overlay.installPlacementRules([rule],
                                  generation: generation,
                                  pageID: firstPageID,
                                  requestID: firstRequestID)
    try overlay.armPlacement(generation: generation)
    overlay.finishForLifecycle()
    XCTAssertNil(overlay.beginPlacementRuleScan(generation: generation, pageID: firstPageID),
                 "Re-entering placement on the active page reuses its completed scan")

    let secondPage = try XCTUnwrap(fixture.view.documentCoordinator.document?.pages[1].page)
    fixture.view.documentView.go(to: secondPage)
    fixture.view.documentViewDidNavigate(to: secondPage)
    let secondOverlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: secondPage))
    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willDisplayOverlayView: secondOverlay,
                                         for: secondPage)
    let secondPageID = fixture.pages[1]
    let secondRequestID = try XCTUnwrap(overlay.beginPlacementRuleScan(
      generation: generation, pageID: secondPageID))
    XCTAssertNotEqual(secondRequestID, firstRequestID)

    let firstPage = try XCTUnwrap(fixture.view.documentCoordinator.document?.pages[0].page)
    fixture.view.documentView.go(to: firstPage)
    fixture.view.documentViewDidNavigate(to: firstPage)
    let firstOverlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: firstPage))
    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willDisplayOverlayView: firstOverlay,
                                         for: firstPage)
    let newFirstPageRequestID = try XCTUnwrap(overlay.beginPlacementRuleScan(
      generation: generation, pageID: firstPageID))
    XCTAssertNotEqual(newFirstPageRequestID, firstRequestID)
    overlay.installPlacementRules([rule],
                                  generation: generation,
                                  pageID: firstPageID,
                                  requestID: firstRequestID)

    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                   195,
                   accuracy: 0.001,
                   "The old page result must not snap after switching away and back")
  }

  func testAutomaticDirectionUsesStrongRTLContentThenReturnsToEmptyDirection() {
    var direction = InkSignPdfTextDirectionState(request: .automatic, fallbackRTL: false)
    XCTAssertFalse(InkSignPdfTextDirectionState.containsStrongRTLCharacter("abc 123 —"))
    XCTAssertTrue(InkSignPdfTextDirectionState.containsStrongRTLCharacter("mixed אבג"))
    XCTAssertTrue(InkSignPdfTextDirectionState.containsStrongRTLCharacter("العربية 123"))
    direction.lockForContent(hasStrongRTL: true)
    XCTAssertTrue(direction.effectiveRTL)
    direction.lockForContent(hasStrongRTL: false)
    XCTAssertFalse(direction.effectiveRTL)
  }

  func testCommittedTextBoundsTransformToTheSameOuterOutline() {
    let pageBounds = CGRect(x: 10, y: 20, width: 30, height: 40)
    let transform = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 3, ty: 4)

    XCTAssertEqual(InkSignPdfTextBoxGeometry.outlineBounds(for: pageBounds,
                                                           transform: transform),
                   CGRect(x: 23, y: 44, width: 60, height: 80))
  }

  func testTextViewportPanningProtectsShortOutlinesAndCentersWideTextAtCaret() {
    let visibleBounds = CGRect(x: 0, y: 0, width: 400, height: 600)
    let shortOutline = CGRect(x: 330, y: 100, width: 100, height: 40)
    let shortCaret = CGRect(x: 420, y: 110, width: 2, height: 20)

    let shortDelta = InkSignPdfTextViewportGeometry.panDelta(
      outline: shortOutline,
      caret: shortCaret,
      visibleBounds: visibleBounds)
    XCTAssertEqual(shortDelta, CGPoint(x: -54, y: 0))
    XCTAssertEqual(shortOutline.offsetBy(dx: shortDelta.x, dy: shortDelta.y).maxX, 376)

    let wideOutline = CGRect(x: 50, y: 100, width: 500, height: 40)
    let wideCaret = CGRect(x: 500, y: 110, width: 2, height: 20)
    let wideDelta = InkSignPdfTextViewportGeometry.panDelta(
      outline: wideOutline,
      caret: wideCaret,
      visibleBounds: visibleBounds)
    XCTAssertEqual(wideDelta.x, -301, accuracy: 0.001)
    XCTAssertEqual(wideCaret.midX + wideDelta.x, 200, accuracy: 0.001)

    let keyboardVisibleBounds = CGRect(x: 0, y: 0, width: 400, height: 420)
    let nearKeyboard = CGRect(x: 100, y: 360, width: 120, height: 80)
    let keyboardDelta = InkSignPdfTextViewportGeometry.panDelta(
      outline: nearKeyboard,
      caret: CGRect(x: 210, y: 410, width: 2, height: 20),
      visibleBounds: keyboardVisibleBounds)
    XCTAssertEqual(keyboardDelta.y, -44, accuracy: 0.001)
  }

  func testTextViewportPanPreservesZoomAndCanonicalAnnotationBounds() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let annotation = makeCenteredTextAnnotation(id: "text-1", text: "note", fontSize: 16,
                                                 pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(annotation,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)
    let history = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history)
    let zoom = fixture.view.documentView.scaleFactor

    fixture.view.panViewport(by: CGPoint(x: -40, y: 30))

    XCTAssertEqual(fixture.view.documentView.scaleFactor, zoom, accuracy: 0.001)
    XCTAssertEqual(history.content.textAnnotations.first?.bounds, annotation.bounds)
  }

  func testTextRendererDrawsMultilineLatinAndRTLInCanonicalPageSpace() {
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "Latin\nשלום עולם",
      fontSize: 18,
      pageSize: CGSize(width: 300, height: 200))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    var didDraw = false
    let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200),
                                        format: format).image { rendererContext in
      UIColor.white.setFill()
      rendererContext.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
      didDraw = InkSignPdfTextRenderer.drawCanonical(
        [annotation],
        pageSize: CGSize(width: 300, height: 200),
        in: rendererContext.cgContext)
    }

    XCTAssertTrue(didDraw)
    let attachment = XCTAttachment(image: image)
    attachment.name = "latin-rtl-text-rendering-manual-review"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertEqual(InkSignPdfTextRenderer.canonicalToPDFTransform(
      for: CGRect(x: -12, y: 24, width: 300, height: 200)).tx, -12, accuracy: 0.001)
  }

  func testNativeExporterShapesAndExportsLTRAndRTLText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let geometry = state.pages[0].geometry
    let latin = makeCenteredTextAnnotation(id: "latin", text: "Latin",
                                           fontSize: 18, pageSize: geometry.mediaBox.size)
    let rtl = InkSignPdfTextAnnotation(id: "rtl", text: "שלום",
                                       bounds: latin.bounds.offsetBy(dx: 0, dy: 30),
                                       fontSize: latin.fontSize,
                                       isRTL: true)
    let snapshot = ExportPageSnapshot(pageIndex: 0,
                                      pageID: state.pages[0].id,
                                      geometry: geometry,
                                      drawingData: PKDrawing().dataRepresentation(),
                                      textAnnotations: [latin, rtl])
    let policy = InkSignPdfCacheArtifactPolicy.shared
    let output = try policy.allocateExportScratch()
    defer { policy.deleteExact(output) }

    do {
      try InkSignPdfNativeExporter.write(sourceURL: state.workingURL,
                                         pages: [snapshot],
                                         outputURL: output)
    } catch {
      if let pdfData = try? Data(contentsOf: output) {
        let attachment = XCTAttachment(data: pdfData,
                                       uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "native-ios-export-validation-failure.pdf"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      throw error
    }

    let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
    for expected in [latin, rtl] {
      let annotation = try XCTUnwrap(page.annotations.first {
        $0.contents == expected.text &&
          $0.type?.caseInsensitiveCompare("FreeText") == .orderedSame
      })
      XCTAssertTrue(annotation.hasAppearanceStream)
      let flags = InkSignPdfVectorAnnotation.flags(of: annotation)
      XCTAssertEqual(flags & InkSignPdfVectorAnnotation.textFlags,
                     InkSignPdfVectorAnnotation.textFlags)
    }
  }

  func testPageContentHistoryRestoresTextAndClearAsOneAction() {
    let history = InkSignPdfPageContentHistory()
    let pageSize = CGSize(width: 400, height: 600)
    let annotation = makeCenteredTextAnnotation(
      id: "text",
      text: "before",
      fontSize: 16,
      pageSize: pageSize)
    history.appendText(annotation)
    history.replaceText(before: annotation,
                        with: annotation.replacingText("after\nline", pageSize: pageSize),
                        type: .textEdit)

    XCTAssertEqual(history.content.textAnnotations.count, 1)
    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate, .textEdit])
    XCTAssertTrue(history.undo())
    XCTAssertEqual(history.content.textAnnotations[0].text, "before")
    XCTAssertTrue(history.redo())
    XCTAssertEqual(history.content.textAnnotations[0].text, "after\nline")

    history.clear()
    XCTAssertTrue(history.content.isEmpty)
    XCTAssertTrue(history.undo())
    XCTAssertEqual(history.content.textAnnotations,
                   [annotation.replacingText("after\nline", pageSize: pageSize)])
    XCTAssertTrue(history.state.isDirty)
  }

  func testPageContentHistoryIsPageLocalAndSnapshotCarriesCommittedText() {
    let first = InkSignPdfPageContentHistory()
    let second = InkSignPdfPageContentHistory()
    let annotation = makeCenteredTextAnnotation(
      id: "first",
      text: "page one",
      fontSize: 18,
      pageSize: CGSize(width: 300, height: 300))

    first.appendText(annotation)

    XCTAssertEqual(first.content.textAnnotations, [annotation])
    XCTAssertTrue(first.state.isDirty)
    XCTAssertFalse(second.state.isDirty)
  }

  func testTextInteractionRejectsPlacementWithoutReadyPresentation() {
    let overlay = InkSignPdfTextInteractionOverlay(frame: .zero)

    XCTAssertThrowsError(try overlay.armPlacement(generation: 0)) { error in
      guard let textError = error as? InkSignView.TextError,
            case .notReady = textError else {
        return XCTFail("text placement must reject before a page overlay is ready")
      }
    }
  }

  func testTextPlacementOnAndOffAreIdempotent() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try fixture.view.insertAnnotationOn()
    try fixture.view.insertAnnotationOn()
    XCTAssertTrue(overlay.hasPendingPlacement())
    XCTAssertNil(textEditor(in: overlay))

    try fixture.view.insertAnnotationOff()
    try fixture.view.insertAnnotationOff()
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNil(textEditor(in: overlay))
  }

  func testTextPlacementConsumesOneRoutedTap() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let placementPoint = CGPoint(x: 120, y: 180)

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.hitTest(placementPoint, with: nil) === overlay)
    XCTAssertTrue(overlay.routePlacementTap(at: placementPoint))
    XCTAssertFalse(overlay.hasPendingPlacement())
    let firstEditor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertTrue(overlay.interactionMode() == .textediting)

    let secondPoint = CGPoint(x: 20, y: 380)
    _ = overlay.routeTap(at: secondPoint)
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations.count, 0)
    XCTAssertNil(overlay.hitTest(secondPoint, with: nil))
    XCTAssertFalse(firstEditor.isDescendant(of: overlay))
  }

  func testTextPlacementOutsideTapDiscardsEmptyDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)

    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    let outside = CGPoint(x: 10, y: 390)

    _ = overlay.routeTap(at: outside)
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertFalse(editor.isDescendant(of: overlay))
    XCTAssertTrue(fixture.view.documentCoordinator.document?.activePage.history.content.isEmpty == true)
  }

  func testTextPlacementOutsideTapUsesTransformedEditorCoordinates() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.transform = CGAffineTransform(rotationAngle: .pi / 4)

    let inside = editor.convert(CGPoint(x: editor.bounds.midX,
                                        y: editor.bounds.midY), to: overlay)
    _ = overlay.routeTap(at: inside)
    XCTAssertTrue(textEditor(in: overlay) === editor)

    let outside = editor.convert(CGPoint(x: editor.bounds.maxX + 20,
                                         y: editor.bounds.midY), to: overlay)
    _ = overlay.routeTap(at: outside)
    XCTAssertNil(textEditor(in: overlay))
  }

  func testTextPlacementOutsideTapCommitsNonEmptyDraft() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "signed"
    overlay.textViewDidChange(editor)
    XCTAssertTrue(overlay.interactionMode() == .textediting)

    _ = overlay.routeTap(at: CGPoint(x: 10, y: 390))
    let annotations = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].text, "signed")
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.history.undoStack.map(\.type), [.textCreate])
  }

  func testTextPlacementCancelsOnModeAndPageChange() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let firstPageID = fixture.pages[0]

    try overlay.armPlacement(generation: generation)
    XCTAssertNil(overlay.beginPlacementRuleScan(generation: generation, pageID: firstPageID),
                 "Entering placement starts a scan for the active page")
    fixture.view.setInteractionMode(editing: true)
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNil(overlay.beginPlacementRuleScan(generation: generation, pageID: firstPageID),
                 "Leaving placement keeps the active page's scan result")

    try overlay.armPlacement(generation: generation)
    try fixture.view.switchPage(to: 1) { result in
      if case .failure(let error) = result {
        XCTFail("unexpected page switch failure: \(error)")
      }
    }
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNotNil(overlay.beginPlacementRuleScan(generation: generation,
                                                   pageID: fixture.pages[1]),
                    "Changing pages clears the previous page's scan")
  }

  func testTextPlacementCancelsOnDocumentReplacementAndDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    fixture.view.beginLoad("",
                          zoom: nil,
                          focus: nil,
                          fitToPage: true,
                          promise: Promise<PageInfo>())
    XCTAssertFalse(overlay.hasPendingPlacement())

    let disposalFixture = makeFixture(pageCount: 1)
    defer { disposalFixture.window.isHidden = true }
    let disposalOverlay = disposalFixture.view.textInteractionOverlay
    try disposalOverlay.armPlacement(generation: disposalFixture.view.documentCoordinator.generation)
    disposalFixture.view.dispose()
    XCTAssertFalse(disposalOverlay.hasPendingPlacement())
  }

  func testRTLTextKeepsCenteredPlacementAndInnerBottomOnCommit() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    overlay.setTextDirection(.rtl)
    let placementPoint = CGPoint(x: 180, y: 140)
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: placementPoint))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "שלום"
    overlay.textViewDidChange(editor)

    _ = overlay.routeTap(at: CGPoint(x: 10, y: 390))

    let annotations = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].bounds.midX, placementPoint.x, accuracy: 0.001)
    XCTAssertEqual(annotations[0].bounds.maxY - InkSignPdfTextStyle.presentationInsets.bottom,
                   placementPoint.y,
                   accuracy: 0.001)
  }

  func testLiveEditorLayoutKeepsCaretVisibleAcrossWrappedTextDeletionAndFontChange() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))

    editor.text = "Invoice אבג 123 — العربية 🖋️ with a long line that wraps\nSecond line"
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    overlay.textViewDidChange(editor)
    let wrappedSize = editor.bounds.size
    let caret = try XCTUnwrap(editor.selectedTextRange.map { editor.caretRect(for: $0.end) })

    XCTAssertGreaterThan(wrappedSize.height, InkSignPdfTextStyle.font(size: 16).lineHeight)
    XCTAssertEqual(editor.bounds.width,
                   editor.textContainer.size.width + editor.textContainerInset.left +
                    editor.textContainerInset.right,
                   accuracy: 0.001)
    XCTAssertTrue(editor.bounds.insetBy(dx: -1, dy: -1).intersects(caret))

    _ = try overlay.increaseTextSize()
    XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 17, accuracy: 0.001)
    XCTAssertEqual(editor.bounds.width,
                   editor.textContainer.size.width + editor.textContainerInset.left +
                    editor.textContainerInset.right,
                   accuracy: 0.001)
    XCTAssertTrue(editor.bounds.insetBy(dx: -1, dy: -1).intersects(
      editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .zero))

    editor.text = ""
    overlay.textViewDidChange(editor)
    let emptyCaret = try XCTUnwrap(editor.selectedTextRange.map { editor.caretRect(for: $0.end) })
    XCTAssertTrue(editor.bounds.insetBy(dx: -1, dy: -1).intersects(emptyCaret))
  }

  func testLiveEditorUsesFinalTextContainerWidthForLongLTRAndRTLLines() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    for (isRTL, direction) in [(false, TextDirection.ltr), (true, TextDirection.rtl)] {
      overlay.setTextDirection(direction)
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
      XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      editor.text = isRTL
        ? "עברית طويلة מאוד 123 العربية — سطر طويل يلتف عدة مرات"
        : "A deliberately long LTR line that wraps across the available page width"
      editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
      overlay.textViewDidChange(editor)

      XCTAssertEqual(editor.bounds.width,
                     editor.textContainer.size.width + editor.textContainerInset.left +
                      editor.textContainerInset.right,
                     accuracy: 0.001)
      XCTAssertGreaterThan(editor.bounds.height,
                           InkSignPdfTextStyle.font(size: 16).lineHeight)
      let caret = try XCTUnwrap(editor.selectedTextRange.map { editor.caretRect(for: $0.end) })
      XCTAssertTrue(editor.bounds.insetBy(dx: -1, dy: -1).intersects(caret))
      let measuredBounds = editor.bounds
      let committedText = editor.text
      overlay.finishForLifecycle()
      let annotation = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage
        .history.content.textAnnotations.first { $0.text == committedText })
      XCTAssertEqual(annotation.bounds.width, measuredBounds.width, accuracy: 0.001)
      XCTAssertEqual(annotation.bounds.height, measuredBounds.height, accuracy: 0.001)
    }
  }

  func testTextContainerWidthContainsCaretAfterTrailingSpacesInBothDirections() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    for (direction, text) in [(TextDirection.ltr, "Text   "),
                              (TextDirection.rtl, "שלום   ")] {
      overlay.setTextDirection(direction)
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
      XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      editor.text = text
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
      overlay.textViewDidChange(editor)

      let caret = try XCTUnwrap(editor.selectedTextRange.map { editor.caretRect(for: $0.end) })
      let textContainerBounds = editor.bounds.inset(by: editor.textContainerInset)
      XCTAssertTrue(textContainerBounds.contains(caret),
                    "The insertion point must fit inside the final TextKit container for \(direction)")
      overlay.finishForLifecycle()
    }
  }

  func testTextOverlayAndPencilKitCanvasAreSeparateHitTestSiblings() {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }

    let overlay = fixture.view.textInteractionOverlay
    let canvas = fixture.view.canvasView
    XCTAssertNotNil(canvas.superview)
    XCTAssertTrue(overlay.superview === canvas.superview)
    XCTAssertFalse(overlay.isDescendant(of: canvas))
  }

  func testLongPressIsEligibleOnlyWhenTouchStartsOnCommittedText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let annotation = makeCenteredTextAnnotation(id: "text-1", text: "note",
                                                 fontSize: 16,
                                                 pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(annotation,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)

    XCTAssertEqual(overlay.dragTarget(at: CGPoint(x: annotation.bounds.midX,
                                                   y: annotation.bounds.midY)), annotation.id)
    XCTAssertNil(overlay.dragTarget(at: CGPoint(x: 10, y: 390)))
  }

  func testUnselectedLongPressCanMoveTextInOneHistoryAction() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let original = makeCenteredTextAnnotation(id: "text-1", text: "note", fontSize: 16,
                                               pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(original,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)
    let start = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
    let destination = CGPoint(x: start.x + 28, y: start.y - 13)
    let history = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history)

    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.changed, at: destination, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: destination, selectedOnly: false))

    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate, .textMove])
    XCTAssertEqual(history.content.textAnnotations.first?.position,
                   CGPoint(x: original.position.x + 28, y: original.position.y - 13))
  }

  func testSelectedDragCancellationAndPageChangeDoNotCommitMoves() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let original = makeCenteredTextAnnotation(id: "text-1", text: "note", fontSize: 16,
                                               pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(original,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)
    let start = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
    let destination = CGPoint(x: start.x + 30, y: start.y + 20)
    let history = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history)

    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.changed, at: destination, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.cancelled, at: destination, selectedOnly: true))
    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate])
    XCTAssertEqual(history.content.textAnnotations.first, original)

    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: true))
    XCTAssertTrue(fixture.view.documentCoordinator.selectPage(at: 1))
    XCTAssertFalse(overlay.routeDrag(.changed, at: destination, selectedOnly: true))
    XCTAssertFalse(overlay.routeDrag(.ended, at: destination, selectedOnly: true))
    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate])
    XCTAssertEqual(history.content.textAnnotations.first, original)
  }

  func testStationaryTapOnSelectedTextOpensTheEditor() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let annotation = makeCenteredTextAnnotation(id: "text-1", text: "note", fontSize: 16,
                                                 pageSize: fixture.view.activePageSize())
    fixture.view.appendTextAnnotation(annotation,
                                      generation: fixture.view.documentCoordinator.generation,
                                      pageIndex: 0)
    let point = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
    XCTAssertTrue(overlay.routeDrag(.began, at: point, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: point, selectedOnly: false))

    XCTAssertTrue(overlay.routeTap(at: point))
    XCTAssertEqual(textEditor(in: overlay)?.text, "note")
  }

  func testTextAnnotationIDsAreMonotonicAndUnique() {
    let view = InkSignView()

    XCTAssertEqual(view.allocateTextAnnotationID(), "text-1")
    XCTAssertEqual(view.allocateTextAnnotationID(), "text-2")
  }

}
