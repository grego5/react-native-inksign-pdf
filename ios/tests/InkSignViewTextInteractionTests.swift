import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewTextInteractionTests: XCTestCase, InkSignViewTestSupport {
  func testHasInkTracksActivePageCommittedInkHistory() throws {
    let emptyView = InkSignView()
    XCTAssertFalse(try emptyView.hasInk())
    emptyView.dispose()

    let fixture = makeFixture(pageCount: 2, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let page = try XCTUnwrap(view.documentCoordinator.document?.activePage)
    let before = page.history.content
    let point = PKStrokePoint(location: CGPoint(x: 80, y: 90),
                              timeOffset: 0,
                              size: CGSize(width: 4, height: 4),
                              opacity: 1,
                              force: 0.5,
                              azimuth: 0,
                              altitude: .pi / 2)
    let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                          path: PKStrokePath(controlPoints: [point], creationDate: Date()),
                          transform: .identity,
                          mask: nil)
    XCTAssertTrue(page.history.record(type: .ink,
                                     before: before,
                                     after: before.replacingDrawing(PKDrawing(strokes: [stroke]))))
    XCTAssertTrue(try view.hasInk())

    let annotationDraft = makeCenteredTextAnnotation(id: 42, text: "Keep", fontSize: 16,
                                                     pageSize: page.geometry.displaySize)
    let annotation = try appendTextAnnotationForTest(annotationDraft, in: view, pageIndex: 1)
    let original = page.history.content
    try view.clearInk()
    XCTAssertFalse(try view.hasInk())
    XCTAssertEqual(page.history.content.textAnnotations, [annotation])
    let revision = page.history.revision
    try view.clearInk()
    XCTAssertEqual(page.history.revision, revision)
    try view.undo()
    XCTAssertTrue(page.history.content.equals(original))
    try view.redo()
    XCTAssertFalse(try view.hasInk())
    XCTAssertEqual(page.history.content.textAnnotations, [annotation])
    try view.undo()
    try view.undo() // Restore the original ink-only fixture before navigation checks.

    _ = try view.switchPage(to: 0)
    XCTAssertFalse(try view.hasInk())
    _ = try view.switchPage(to: 1)
    XCTAssertTrue(try view.hasInk())

    try view.undo()
    XCTAssertFalse(try view.hasInk())
    try view.redo()
    XCTAssertTrue(try view.hasInk())
    try view.clear()
    XCTAssertFalse(try view.hasInk())
  }

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

  func testAutomaticDirectionIsSnapshottedWhenPlacementIsArmed() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    fixture.view.container.semanticContentAttribute = .forceRightToLeft
    try fixture.view.setTextDirection(direction: .auto)

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    fixture.view.container.semanticContentAttribute = .forceLeftToRight
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    editor.text = "direction is saved"
    overlay.textViewDidChange(editor)
    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history
      .content.textAnnotations.first)
    XCTAssertTrue(annotation.isRTL)
  }

  func testDirectionCommandUpdatesActiveDraftWithoutCommitting() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    view.container.semanticContentAttribute = .forceLeftToRight
    try view.setTextDirection(direction: .ltr)
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "draft text"
    overlay.textViewDidChange(editor)
    let originalOrigin = editor.frame.origin

    try view.setTextDirection(direction: .rtl)
    XCTAssertEqual(editor.text, "draft text")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertEqual(editor.frame.origin.x, originalOrigin.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.origin.y, originalOrigin.y, accuracy: 0.001)
    let rightEdgeAfterSwitch = editor.frame.maxX
    editor.text += " with more words"
    overlay.textViewDidChange(editor)
    XCTAssertEqual(editor.frame.maxX, rightEdgeAfterSwitch, accuracy: 0.001)
    XCTAssertTrue(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.isEmpty == true)

    view.container.semanticContentAttribute = .forceRightToLeft
    try view.setTextDirection(direction: .auto)
    XCTAssertEqual(editor.text, "draft text with more words")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertTrue(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.isEmpty == true)

    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertEqual(annotation.text, "draft text with more words")
    XCTAssertTrue(annotation.isRTL)
  }

  func testDirectionCommandUpdatesReopenedFlowBoundEditor() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let original = try insertTextForTest("bounded text",
      bounds: TextAnnotationBounds(x: 150, y: 100, width: 130, height: 80),
      options: TextAnnotationOptions(fontSize: nil, color: nil, direction: .ltr,
        maxLines: nil, alignment: .start, verticalAnchor: nil), in: view)
    let tapPoint = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
    XCTAssertTrue(overlay.routeTap(at: tapPoint))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    let pageOrigin = editor.frame.origin
    let flowBounds = original.flowBounds
    try view.setTextDirection(direction: .rtl)
    XCTAssertEqual(editor.text, "bounded text")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertEqual(editor.frame.origin.x, pageOrigin.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.origin.y, pageOrigin.y, accuracy: 0.001)
    XCTAssertEqual(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first, original)

    overlay.finishForLifecycle()
    let updated = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertTrue(updated.isRTL)
    XCTAssertEqual(updated.flowBounds, flowBounds)

    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: updated.bounds.midX,
                                                y: updated.bounds.midY)))
    let reopenedEditor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(reopenedEditor.text, "bounded text")
    XCTAssertEqual(reopenedEditor.textAlignment, .right)
    XCTAssertEqual(reopenedEditor.semanticContentAttribute, .forceRightToLeft)
  }

  func testProgrammaticTextUsesPageBoundsAndDirectionPrecedence() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    view.container.semanticContentAttribute = .forceRightToLeft
    try view.setTextDirection(direction: .ltr)

    try insertTextForTest("left to right",
      bounds: TextAnnotationBounds(x: 80, y: 50, width: 220, height: 350),
      options: nil, in: view)
    try insertTextForTest("right to left",
      bounds: TextAnnotationBounds(x: 30, y: 80, width: 80, height: 40),
      options: TextAnnotationOptions(fontSize: nil, color: nil, direction: .auto,
        maxLines: nil, alignment: .start, verticalAnchor: nil), in: view)
    try view.setTextDirection(direction: .auto)
    try insertTextForTest("resolved app direction",
      bounds: TextAnnotationBounds(x: 0, y: 140, width: 100, height: 260),
      options: nil, in: view)

    let annotations = try XCTUnwrap(view.documentCoordinator.document?.activePage.history
      .content.textAnnotations)
    XCTAssertEqual(annotations.map(\.isRTL), [false, true, true])
    XCTAssertEqual(annotations[0].flowBounds,
                   CGRect(x: 80, y: 50, width: 220, height: 350))
    XCTAssertEqual(annotations[1].flowBounds,
                   CGRect(x: 30, y: 80, width: 80, height: 40))
    XCTAssertEqual(annotations[2].flowBounds,
                   CGRect(x: 0, y: 140, width: 100, height: 260))
    XCTAssertGreaterThanOrEqual(annotations[1].bounds.minX, 30)
    XCTAssertLessThanOrEqual(annotations[1].bounds.maxX, 110)
    XCTAssertGreaterThanOrEqual(annotations[1].bounds.minY, 80)
    XCTAssertLessThanOrEqual(annotations[1].bounds.maxY, 120)
    XCTAssertNil(textEditor(in: view.textInteractionOverlay))
  }

  func testProgrammaticTextKeepsCompleteLinesAndVerticalAnchorMetadata() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }

    try insertTextForTest(
      "first line\nsecond line\nthird line",
      bounds: TextAnnotationBounds(x: 80, y: 180, width: 200, height: 100),
      options: TextAnnotationOptions(fontSize: nil, color: nil, direction: .ltr,
        maxLines: 2, alignment: .start, verticalAnchor: .bottom), in: fixture.view)
    let annotation = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history
      .content.textAnnotations.first)
    let flowBounds = try XCTUnwrap(annotation.flowBounds)
    XCTAssertEqual(flowBounds.minX, 80, accuracy: 0.01)
    XCTAssertEqual(flowBounds.maxX, 280, accuracy: 0.01)
    XCTAssertEqual(flowBounds.minY, 180, accuracy: 0.01)
    XCTAssertEqual(flowBounds.maxY, 280, accuracy: 0.01)
    XCTAssertEqual(annotation.maxLines, 2)
    XCTAssertEqual(annotation.verticalAnchor, .bottom)
    XCTAssertEqual(annotation.bounds.maxY, flowBounds.maxY, accuracy: 0.01)
    XCTAssertLessThanOrEqual(annotation.bounds.height,
                             2 * InkSignPdfTextStyle.font(size: annotation.fontSize).lineHeight + 0.01)

    let lineHeight = InkSignPdfTextStyle.font(size: annotation.fontSize).lineHeight
    try insertTextForTest(
      "only visible line\nhidden second line",
      bounds: TextAnnotationBounds(x: 20, y: 20, width: 160,
                                    height: Double(lineHeight + 0.1)),
      options: TextAnnotationOptions(fontSize: nil, color: nil, direction: .ltr,
        maxLines: 2, alignment: .start, verticalAnchor: .top), in: fixture.view)
    let heightLimited = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history
      .content.textAnnotations.last)
    XCTAssertLessThanOrEqual(heightLimited.bounds.height, lineHeight + 0.01)
    XCTAssertGreaterThan(heightLimited.bounds.height, 0)
    XCTAssertEqual(heightLimited.maxLines, 2)

    let moved = annotation.moving(to: CGPoint(x: annotation.position.x + 10,
                                              y: annotation.position.y + 10),
                                 pageSize: CGSize(width: 400, height: 400))
    let resized = moved.changingFontSize(to: annotation.fontSize + 1,
                                         pageSize: CGSize(width: 400, height: 400))
    XCTAssertEqual(resized.maxLines, 2)
    XCTAssertEqual(resized.verticalAnchor, .bottom)
    XCTAssertEqual(resized.flowBounds?.maxY, moved.flowBounds?.maxY)
  }

  func testManualPlacementOptionsConstrainTypingAndKeepBottomEdge() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let options = TextModeOptions(direction: .ltr,
                                        width: 120,
                                        height: 120,
                                        maxLines: 2,
                                        alignment: .start,
                                        verticalAnchor: .bottom, x: nil, y: nil, zoom: nil)
    try view.setMode(mode: .text, options: options)
    XCTAssertFalse(overlay.routePlacementTap(
      at: CGPoint(x: 300, y: 300).applying(try XCTUnwrap(view.pageToOverlayTransform))))
    XCTAssertTrue(overlay.hasPendingPlacement())
    let tap = CGPoint(x: 50, y: 160).applying(try XCTUnwrap(view.pageToOverlayTransform))
    XCTAssertTrue(overlay.routePlacementTap(at: tap))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.textContainer.size.width, 120, accuracy: 0.01)
    let anchoredBottom = editor.frame.maxY
    editor.insertText("First line\nSecond line")
    XCTAssertEqual(editor.text, "First line\nSecond line")
    XCTAssertEqual(editor.frame.maxY, anchoredBottom, accuracy: 0.01)

    let insertionCaret = editor.selectedRange
    editor.insertText("\nThird line")
    XCTAssertEqual(editor.text, "First line\nSecond line")
    XCTAssertEqual(editor.selectedRange, insertionCaret)

    editor.selectedRange = NSRange(location: 0, length: 5)
    let replacementSelection = editor.selectedRange
    editor.insertText("A replacement that cannot fit in the bounded editor")
    XCTAssertEqual(editor.text, "First line\nSecond line")
    XCTAssertEqual(editor.selectedRange, replacementSelection)

    let acceptedText = editor.text ?? ""
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.deleteBackward()
    XCTAssertEqual(editor.text, String(acceptedText.dropLast()))
    XCTAssertEqual(editor.frame.maxY, anchoredBottom, accuracy: 0.01)

    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertEqual(annotation.text, String(acceptedText.dropLast()))
    XCTAssertEqual(annotation.maxLines, 2)
    XCTAssertEqual(annotation.verticalAnchor, .bottom)
    XCTAssertEqual(annotation.flowBounds?.minX, 50)
    XCTAssertEqual(annotation.flowBounds?.maxX, 170)
    XCTAssertEqual(annotation.flowBounds?.minY, 160)
    XCTAssertEqual(annotation.flowBounds?.maxY, 280)
    XCTAssertEqual(annotation.bounds.maxY, 280, accuracy: 0.01)

    let annotationTap = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
      .applying(try XCTUnwrap(view.pageToOverlayTransform))
    XCTAssertTrue(overlay.routeTap(at: annotationTap))
    let reopenedEditor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(reopenedEditor.textContainer.size.width, 120, accuracy: 0.01)
    let reopenedText = reopenedEditor.text ?? ""
    reopenedEditor.insertText("\nThird line")
    XCTAssertEqual(reopenedEditor.text, reopenedText)
    overlay.finishForLifecycle()
    let reopened = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertEqual(reopened.maxLines, 2)
    XCTAssertEqual(reopened.verticalAnchor, .bottom)
  }

  func testAutoSizedManualPlacementAppliesMaxLines() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    try view.setMode(mode: .text, options: TextModeOptions(
      direction: .ltr,
      width: nil,
      height: nil,
      maxLines: 2,
      alignment: .start,
      verticalAnchor: .top, x: nil, y: nil, zoom: nil))
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 40, y: 60)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("first line\nsecond line")
    XCTAssertEqual(editor.text, "first line\nsecond line")
    let acceptedSelection = editor.selectedRange
    editor.insertText("\nthird line")
    XCTAssertEqual(editor.text, "first line\nsecond line")
    XCTAssertEqual(editor.selectedRange, acceptedSelection)

    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertNil(annotation.flowBounds)
    XCTAssertEqual(annotation.maxLines, 2)
    XCTAssertEqual(annotation.text, "first line\nsecond line")
    XCTAssertTrue(InkSignPdfTextRenderer.fitsMaxLines(annotation.text,
                                                      fontSize: CGFloat(annotation.fontSize),
                                                      isRTL: false,
                                                      maxLines: 2,
                                                      maximumWidth: view.activePageSize().width,
                                                      alignment: .start))
    XCTAssertFalse(InkSignPdfTextRenderer.fitsMaxLines(annotation.text,
                                                       fontSize: CGFloat(annotation.fontSize),
                                                       isRTL: false,
                                                       maxLines: 1,
                                                       maximumWidth: view.activePageSize().width,
                                                       alignment: .start))
  }

  func testOverfullReflowedDraftAllowsSuccessiveBackspaces() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let flowBounds = CGRect(x: 50, y: 160, width: 160, height: 120)
    try view.setMode(mode: .text, options: TextModeOptions(
      direction: .ltr,
      width: 160,
      height: 120,
      maxLines: 2,
      alignment: .start,
      verticalAnchor: .bottom, x: nil, y: nil, zoom: nil))
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 50, y: 160)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    let originalText = "MMMMMMMMM\nWWWWWWWWW"
    editor.insertText(originalText)
    XCTAssertEqual(editor.text, originalText)

    try view.setTextDirection(direction: .rtl)
    var fontSize = 16.0
    let afterTwoBackspaces = String(originalText.dropLast(2))
    for _ in 0..<56 {
      let currentFits = InkSignPdfTextRenderer.fits(
        originalText,
        fontSize: CGFloat(fontSize),
        isRTL: true,
        flowBounds: flowBounds,
        maxLines: 2)
      let shortenedFits = InkSignPdfTextRenderer.fits(
        afterTwoBackspaces,
        fontSize: CGFloat(fontSize),
        isRTL: true,
        flowBounds: flowBounds,
        maxLines: 2)
      if !currentFits && !shortenedFits { break }
      fontSize = try view.textInteractionOverlay.increaseTextSize()
    }
    XCTAssertFalse(InkSignPdfTextRenderer.fits(originalText,
                                                fontSize: CGFloat(fontSize),
                                                isRTL: true,
                                                flowBounds: flowBounds,
                                                maxLines: 2))
    XCTAssertFalse(InkSignPdfTextRenderer.fits(afterTwoBackspaces,
                                                fontSize: CGFloat(fontSize),
                                                isRTL: true,
                                                flowBounds: flowBounds,
                                                maxLines: 2))
    XCTAssertEqual(editor.text, originalText)
    XCTAssertEqual(editor.selectedRange.location, (originalText as NSString).length)

    for expectedText in [String(originalText.dropLast()), afterTwoBackspaces] {
      editor.deleteBackward()
      XCTAssertEqual(editor.text, expectedText)
      XCTAssertFalse(InkSignPdfTextRenderer.fits(expectedText,
                                                  fontSize: CGFloat(fontSize),
                                                  isRTL: true,
                                                  flowBounds: flowBounds,
                                                  maxLines: 2))
    }
  }

  func testManualPlacementSnapshotsDirectionWhenArmed() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    try view.setTextDirection(direction: .ltr)
    try view.setMode(mode: .text, options: TextModeOptions(
      direction: nil,
      width: nil,
      height: nil,
      maxLines: 2,
      alignment: .start,
      verticalAnchor: nil, x: nil, y: nil, zoom: nil))
    try view.setTextDirection(direction: .rtl)

    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 100)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("direction snapshot")
    overlay.finishForLifecycle()

    let annotation = try XCTUnwrap(view.documentCoordinator.document?.activePage.history.content
      .textAnnotations.first)
    XCTAssertFalse(annotation.isRTL)
    XCTAssertNil(annotation.flowBounds)
  }

  func testReopeningCommittedAnnotationUsesItsSavedDirection() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let annotation = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 6, text: "שלום",
                                 fontSize: 16,
                                 pageSize: fixture.view.activePageSize(),
                                 isRTL: true),
      in: fixture.view,
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
      try fixture.view.setTextDirection(direction: direction)
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
    let anchor = InkSignPdfTextBoxGeometry.PlacementAnchor(x: 80,
                                                           y: 50,
                                                           horizontal: .centered,
                                                           vertical: .bottom(.innerTextArea))

    let compact = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                         size: CGSize(width: 40, height: 28),
                                                         insets: insets,
                                                         pageSize: pageSize)
    XCTAssertEqual(compact, CGRect(x: 60, y: 28, width: 40, height: 28))
    XCTAssertEqual(compact.midX, anchor.x)
    XCTAssertEqual(compact.maxY - insets.bottom, anchor.y)

    let expanded = InkSignPdfTextBoxGeometry.initialFrame(anchor: anchor,
                                                          size: CGSize(width: 72, height: 44),
                                                          insets: insets,
                                                          pageSize: pageSize)
    XCTAssertEqual(expanded.midX, anchor.x)
    XCTAssertEqual(expanded.maxY - insets.bottom, anchor.y)

    let snapped = InkSignPdfTextBoxGeometry.initialFrame(
      anchor: .init(x: 80, y: 50, horizontal: .centered, vertical: .bottom(.outerBox)),
      size: CGSize(width: 40, height: 28), insets: insets, pageSize: pageSize)
    XCTAssertEqual(snapped, CGRect(x: 60, y: 22, width: 40, height: 28))
    XCTAssertEqual(snapped.maxY, 50)

    let edge = InkSignPdfTextBoxGeometry.initialFrame(
      anchor: .init(x: 0, y: 0, horizontal: .centered, vertical: .bottom(.innerTextArea)),
      size: CGSize(width: 40, height: 28), insets: insets, pageSize: pageSize)
    XCTAssertEqual(edge.origin, .zero)

    let ltrAnchor = InkSignPdfTextBoxGeometry.PlacementAnchor(
      x: 100, y: 20, horizontal: .left, vertical: .top)
    let rtlAnchor = InkSignPdfTextBoxGeometry.PlacementAnchor(
      x: 100, y: 20, horizontal: .right, vertical: .top)
    let ltrCompact = InkSignPdfTextBoxGeometry.initialFrame(anchor: ltrAnchor,
                                                           size: CGSize(width: 40, height: 20),
                                                           insets: .zero,
                                                           pageSize: pageSize)
    let ltrExpanded = InkSignPdfTextBoxGeometry.initialFrame(anchor: ltrAnchor,
                                                             size: CGSize(width: 72, height: 20),
                                                             insets: .zero,
                                                             pageSize: pageSize)
    let rtlCompact = InkSignPdfTextBoxGeometry.initialFrame(anchor: rtlAnchor,
                                                           size: CGSize(width: 40, height: 20),
                                                           insets: .zero,
                                                           pageSize: pageSize)
    let rtlExpanded = InkSignPdfTextBoxGeometry.initialFrame(anchor: rtlAnchor,
                                                             size: CGSize(width: 72, height: 20),
                                                             insets: .zero,
                                                             pageSize: pageSize)
    XCTAssertEqual(ltrCompact.minX, ltrExpanded.minX)
    XCTAssertGreaterThan(ltrExpanded.maxX, ltrCompact.maxX)
    XCTAssertEqual(rtlCompact.maxX, rtlExpanded.maxX)
    XCTAssertLessThan(rtlExpanded.minX, rtlCompact.minX)
  }

  func testInitialPlacementIsCenteredForLTRRTLAndAutomaticDirection() throws {
    let tap = CGPoint(x: 150, y: 140)
    var frames: [CGRect] = []
    let directions: [TextDirection] = [.auto, .ltr, .rtl]
    for direction in directions {
      let fixture = makeFixture(pageCount: 1)
      let overlay = fixture.view.textInteractionOverlay
      try fixture.view.setTextDirection(direction: direction)
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
    let annotation = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note", fontSize: 16,
                                 pageSize: fixture.view.activePageSize()),
      in: fixture.view,
      pageIndex: 0)
    let history = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.history)
    let zoom = fixture.view.documentView.scaleFactor

    fixture.view.panViewport(by: CGPoint(x: -40, y: 30))

    XCTAssertEqual(fixture.view.documentView.scaleFactor, zoom, accuracy: 0.001)
    XCTAssertEqual(history.content.textAnnotations.first?.bounds, annotation.bounds)
  }

  func testTextRendererDrawsMultilineLatinAndRTLInCanonicalPageSpace() {
    let annotation = makeCenteredTextAnnotation(
      id: 3,
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
    XCTAssertEqual(PageGeometry(mediaBox: CGRect(x: -12, y: 24, width: 300, height: 200),
                                rotation: 0).canonicalToPDFTransform.tx,
                   -12, accuracy: 0.001)
  }

  func testNativeExporterShapesAndExportsLTRAndRTLText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let state = try XCTUnwrap(fixture.view.documentCoordinator.document)
    let geometry = state.pages[0].geometry
    let latin = makeCenteredTextAnnotation(id: 7, text: "Latin",
                                           fontSize: 18, pageSize: geometry.mediaBox.size)
    let rtl = InkSignPdfTextAnnotation(id: 5, text: "שלום",
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
      id: 3,
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
      id: 4,
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

  func testTextModeViewportIsDeferredAndIndependentOfDoubleTap() throws {
    let fixture = makeFixture(pageCount: 1)
    let view = fixture.view
    defer { view.dispose(); fixture.window.isHidden = true }
    let overlay = view.textInteractionOverlay
    view.doubleTap = DoubleTapOptions(zoom: 6, enterEditMode: false)
    try awaitModeChange(view.setMode(mode: .view, options: nil).setViewport(options: ViewportOptions(x: 150, y: 200, zoom: 3)))

    func place() throws {
      let tap = CGPoint(x: 150, y: 200).applying(try XCTUnwrap(view.pageToOverlayTransform))
      XCTAssertTrue(overlay.routePlacementTap(at: tap))
      let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        !view.viewportMotion.isRunning
      }, object: nil)
      wait(for: [settled], timeout: 3)
    }
    try view.setMode(mode: .text, options: nil)
    try place()
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "draft"
    overlay.textViewDidChange(editor)
    try view.setMode(mode: .ink, options: nil)
    XCTAssertEqual(view.documentCoordinator.document?.activePage.history.content.textAnnotations.first?.text, "draft")
    XCTAssertNil(textEditor(in: overlay))

    try view.setMode(mode: .text, options: TextModeOptions(
      direction: nil, width: nil, height: nil, maxLines: 1,
      alignment: nil, verticalAnchor: nil, x: nil, y: nil, zoom: nil))
    try place()
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)

    try view.setMode(mode: .text, options: TextModeOptions(
      direction: nil, width: nil, height: nil, maxLines: nil,
      alignment: nil, verticalAnchor: nil, x: 150, y: 200, zoom: 2))
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)
    try place()
    XCTAssertEqual(try view.getViewport().zoom, 2, accuracy: 0.01)

    try awaitModeChange(view.setMode(mode: .view, options: nil).setViewport(options: ViewportOptions(x: nil, y: nil, zoom: nil)))
    let fittedZoom = try view.getViewport().zoom
    try awaitModeChange(view.setMode(mode: .ink, options: nil).setViewport(options: ViewportOptions(x: nil, y: nil, zoom: 3)))
    try view.setMode(mode: .text, options: TextModeOptions(
      direction: nil, width: nil, height: nil, maxLines: nil,
      alignment: nil, verticalAnchor: nil, x: nil, y: nil, zoom: nil))
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)
    try place()
    XCTAssertEqual(try view.getViewport().zoom, fittedZoom, accuracy: 0.01)
    overlay.finishForLifecycle()
    XCTAssertTrue(overlay.interactionMode() == .view)
  }

  func testModeSwitchCancelsArmedTextPlacement() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try fixture.view.setMode(mode: .text, options: nil)
    try fixture.view.setMode(mode: .text, options: nil)
    XCTAssertTrue(overlay.hasPendingPlacement())
    XCTAssertNil(textEditor(in: overlay))

    try fixture.view.setMode(mode: .view, options: nil)
    try fixture.view.setMode(mode: .view, options: nil)
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
    XCTAssertTrue(overlay.interactionMode() == .textedit)

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
    XCTAssertTrue(overlay.interactionMode() == .textedit)

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

  func testPlacementCancelsAtReplacementAdmissionAndOnDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    let rejected = expectation(description: "invalid replacement rejects after clearing")
    let promise = Promise<PageInfo>()
    var stateWasClearedAtRejection = false
    promise.catch { _ in
      stateWasClearedAtRejection = fixture.view.documentCoordinator.document == nil &&
        fixture.view.documentView.document == nil
      rejected.fulfill()
    }
    let pdfQueue = fixture.view.documentCoordinator.pdfQueue
    pdfQueue.suspend()
    fixture.view.beginLoad("",
                          zoom: nil,
                          focus: nil,
                          fitToPage: true,
                          promise: promise)
    XCTAssertFalse(overlay.hasPendingPlacement(),
                   "Replacement admission cancels placement before PDF preparation")
    XCTAssertNil(fixture.view.documentCoordinator.document)
    pdfQueue.resume()
    wait(for: [rejected], timeout: 5)
    XCTAssertTrue(stateWasClearedAtRejection)
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNil(fixture.view.documentCoordinator.document)

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
    try fixture.view.setTextDirection(direction: .rtl)
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

    editor.text = "Ada"
    editor.selectedRange = NSRange(location: 3, length: 0)
    overlay.textViewDidChange(editor)
    let singleLineHeight = editor.bounds.height
    editor.insertText("\n")
    XCTAssertEqual(editor.text, "Ada\n")
    XCTAssertGreaterThan(editor.bounds.height, singleLineHeight)
    editor.text = "Ada\n"
    // Text changes can precede UIKit moving the caret into the empty next line.
    editor.selectedRange = NSRange(location: 3, length: 0)
    overlay.textViewDidChange(editor)
    XCTAssertGreaterThan(editor.bounds.height, singleLineHeight)

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
      try fixture.view.setTextDirection(direction: direction)
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
      try fixture.view.setTextDirection(direction: direction)
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
      XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      editor.text = text
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
      overlay.textViewDidChange(editor)

      let caret = try XCTUnwrap(editor.selectedTextRange.map { editor.caretRect(for: $0.end) })
      let textContainerBounds = editor.bounds.inset(by: editor.textContainerInset)
      let usedRect = editor.layoutManager.usedRect(for: editor.textContainer)
      XCTAssertGreaterThanOrEqual(caret.minX, textContainerBounds.minX,
                                   "Caret starts before the text container for \(direction)")
      XCTAssertLessThanOrEqual(caret.maxX, textContainerBounds.maxX,
                                "Caret ends after the text container for \(direction)")
      XCTAssertTrue(editor.bounds.contains(caret),
                    "Caret \(caret) must remain visible within editor bounds \(editor.bounds); " +
                      "container bounds \(textContainerBounds), container size \(editor.textContainer.size), " +
                      "insets \(editor.textContainerInset), content offset \(editor.contentOffset), " +
                      "used rect \(usedRect), direction \(direction)")
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
    let annotation = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note",
                                 fontSize: 16,
                                 pageSize: fixture.view.activePageSize()),
      in: fixture.view,
      pageIndex: 0)

    XCTAssertEqual(overlay.dragTarget(at: CGPoint(x: annotation.bounds.midX,
                                                   y: annotation.bounds.midY)), annotation.id)
    XCTAssertNil(overlay.dragTarget(at: CGPoint(x: 10, y: 390)))
  }

  func testUnselectedLongPressCanMoveTextInOneHistoryAction() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let original = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note", fontSize: 16,
                                 pageSize: fixture.view.activePageSize()),
      in: fixture.view,
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
    let original = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note", fontSize: 16,
                                 pageSize: fixture.view.activePageSize()),
      in: fixture.view,
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
    let annotation = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note", fontSize: 16,
                                 pageSize: fixture.view.activePageSize()),
      in: fixture.view,
      pageIndex: 0)
    let point = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
    XCTAssertTrue(overlay.routeDrag(.began, at: point, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: point, selectedOnly: false))

    XCTAssertTrue(overlay.routeTap(at: point))
    XCTAssertEqual(textEditor(in: overlay)?.text, "note")
  }

  func testSelectedTextHandleSurvivesDeselectionAndNavigationAndRejectsDisposal() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    guard case .second = try view.getSelectedText() else {
      return XCTFail("An idle viewer has no selected text")
    }
    let annotation = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "note", fontSize: 16,
                                 pageSize: view.activePageSize()),
      in: view, pageIndex: 0)
    let point = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
    let overlay = view.textInteractionOverlay
    XCTAssertTrue(overlay.routeDrag(.began, at: point, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: point, selectedOnly: false))
    guard case .first(let text) = try view.getSelectedText() else {
      return XCTFail("Selected module text must expose a handle")
    }
    XCTAssertEqual(try text.getValue(), "note")
    overlay.finishForLifecycle()
    XCTAssertTrue(view.documentCoordinator.selectPage(at: 1))
    try text.setValue(text: "updated")
    let document = try XCTUnwrap(view.documentCoordinator.document)
    XCTAssertEqual(document.pages[0].history.content.textAnnotations.first?.text, "updated")
    XCTAssertTrue(document.pages[1].history.content.textAnnotations.isEmpty)
    try text.setValue(text: "")
    XCTAssertEqual(try text.getValue(), "")
    XCTAssertTrue(document.pages[0].history.content.textAnnotations.isEmpty)
    view.dispose()
    XCTAssertThrowsError(try text.getValue())
  }

  func testTextTargetIDsAreMonotonicAndUnique() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let pageID = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.id)
    let pageSize = fixture.view.activePageSize()
    let first = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 1, text: "first", fontSize: 16, pageSize: pageSize),
      in: fixture.view, pageIndex: 0)
    let second = try appendTextAnnotationForTest(
      makeCenteredTextAnnotation(id: 2, text: "second", fontSize: 16, pageSize: pageSize),
      in: fixture.view, pageIndex: 0)

    XCTAssertEqual(first.id, 1)
    XCTAssertEqual(second.id, 2)
  }

}
