import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewTextInteractionTests: XCTestCase, InkSignViewTestSupport {
  func testDirtyStateFollowsAppliedTrackedHistoryAcrossPages() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let coordinator = view.documentCoordinator
    let document = try XCTUnwrap(coordinator.document)
    let annotation = makeCenteredTextAnnotation(id: 1, text: "Keep",
      fontSize: 16, pageSize: document.pages[0].geometry.displaySize)
    _ = try appendTextAnnotationForTest(annotation, in: view, pageIndex: 0)
    let first = document.pages[0].history
    XCTAssertTrue(coordinator.isDirty)
    XCTAssertTrue(first.undo())
    XCTAssertFalse(first.state.isDirty)
    XCTAssertTrue(first.state.canRedo)
    XCTAssertFalse(coordinator.isDirty)
    XCTAssertTrue(first.redo())
    XCTAssertTrue(coordinator.isDirty)
    XCTAssertTrue(first.undo())
    coordinator.setStructuralDirty(true)
    XCTAssertTrue(coordinator.isDirty)
  }

  func testPageStateTracksActivePageCommittedInkHistory() throws {
    let emptyView = ViewerCanvas()
    XCTAssertNil(emptyView.viewerDocument)
    emptyView.dispose()

    let fixture = makeFixture(pageCount: 2, activePageIndex: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let pageState = try XCTUnwrap(view.viewerDocument?.activePage)
    let page = try documentPage(view, at: 1)
    let pageZero = try documentPage(view, at: 0)
    let before = pageState.history.content
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
    XCTAssertTrue(pageState.history.record(type: .ink,
                                     before: before,
                                     after: before.replacingDrawing(PKDrawing(strokes: [stroke]))))
    XCTAssertTrue(try page.getState().hasInk)

    let pageInfo = try page.getState()
    let annotationDraft = makeCenteredTextAnnotation(id: 42, text: "Keep", fontSize: 16,
                                                     pageSize: CGSize(width: pageInfo.width,
                                                                      height: pageInfo.height))
    let annotation = try appendTextAnnotationForTest(annotationDraft, in: view, pageIndex: 1)
    let original = pageState.history.content
    try page.clearInk()
    XCTAssertFalse(try page.getState().hasInk)
    XCTAssertEqual(pageState.history.content.textAnnotations, [annotation])
    let revision = pageState.history.revision
    try page.clearInk()
    XCTAssertEqual(pageState.history.revision, revision)
    try page.undo()
    XCTAssertTrue(pageState.history.content.equals(original))
    try page.redo()
    XCTAssertFalse(try page.getState().hasInk)
    XCTAssertEqual(pageState.history.content.textAnnotations, [annotation])
    try page.undo()
    try page.undo() // Restore the original ink-only fixture before navigation checks.

    _ = try view.switchPage(to: 0)
    XCTAssertFalse(try pageZero.getState().hasInk)
    _ = try view.switchPage(to: 1)
    XCTAssertTrue(try page.getState().hasInk)

    try page.undo()
    XCTAssertFalse(try page.getState().hasInk)
    try page.redo()
    XCTAssertTrue(try page.getState().hasInk)
    try page.clear()
    XCTAssertFalse(try page.getState().hasInk)
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
    fixture.view.textDirection = .auto

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    fixture.view.container.semanticContentAttribute = .forceLeftToRight
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    editor.text = "direction is saved"
    overlay.textViewDidChange(editor)
    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history
      .content.textAnnotations.first)
    XCTAssertTrue(annotation.isRTL)
  }

  func testDirectionCommandUpdatesActiveDraftWithoutCommitting() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    view.container.semanticContentAttribute = .forceLeftToRight
    view.textDirection = .ltr
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 140)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "draft text"
    overlay.textViewDidChange(editor)
    let originalOrigin = editor.frame.origin

    view.textDirection = .rtl
    XCTAssertEqual(editor.text, "draft text")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertEqual(editor.frame.origin.x, originalOrigin.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.origin.y, originalOrigin.y, accuracy: 0.001)
    let rightEdgeAfterSwitch = editor.frame.maxX
    editor.text += " with more words"
    overlay.textViewDidChange(editor)
    XCTAssertEqual(editor.frame.maxX, rightEdgeAfterSwitch, accuracy: 0.001)
    XCTAssertTrue(view.viewerDocument?.activePage.history.content
      .textAnnotations.first?.isRTL == true)

    view.container.semanticContentAttribute = .forceRightToLeft
    view.textDirection = .auto
    XCTAssertEqual(editor.text, "draft text with more words")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertTrue(view.viewerDocument?.activePage.history.content
      .textAnnotations.first?.isRTL == true)

    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(view.viewerDocument?.activePage.history.content
      .textAnnotations.first)
    XCTAssertEqual(annotation.text, "draft text with more words")
    XCTAssertTrue(annotation.isRTL)
    let page = try documentPage(view)
    try page.undo()
    XCTAssertTrue(view.viewerDocument!.activePage.history.content.textAnnotations.isEmpty)
    XCTAssertFalse(try page.getState().canUndo)
    try page.redo()
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first, annotation)
  }

  func testDirectionCommandUpdatesReopenedFlowBoundEditor() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let original = try insertTextForTest("bounded text",
      bounds: TextAnnotationBounds(x: 150, y: 100, width: 130, height: 80),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil, color: nil, direction: .ltr,
        maxLines: nil, alignment: .start, verticalAnchor: nil), in: view)
    let tapPoint = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
    XCTAssertTrue(overlay.routeTap(at: tapPoint))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    let pageOrigin = editor.frame.origin
    let flowBounds = original.flowBounds
    view.textDirection = .rtl
    XCTAssertEqual(editor.text, "bounded text")
    XCTAssertEqual(editor.textAlignment, .right)
    XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
    XCTAssertEqual(editor.frame.origin.x, pageOrigin.x, accuracy: 0.001)
    XCTAssertEqual(editor.frame.origin.y, pageOrigin.y, accuracy: 0.001)
    let draft = try XCTUnwrap(view.viewerDocument?.activePage.history.content.textAnnotations.first)
    XCTAssertTrue(draft.isRTL)
    XCTAssertEqual(draft.flowBounds, flowBounds)

    overlay.finishForLifecycle()
    let updated = try XCTUnwrap(view.viewerDocument?.activePage.history.content
      .textAnnotations.first)
    XCTAssertTrue(updated.isRTL)
    XCTAssertEqual(updated.flowBounds, flowBounds)
    let page = try documentPage(view)
    try page.undo()
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first, original)
    try page.redo()
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first, updated)

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
    view.documentCore.appDirectionRTL = true
    view.container.semanticContentAttribute = .forceRightToLeft
    view.textDirection = .ltr

    try insertTextForTest("left to right",
      bounds: TextAnnotationBounds(x: 80, y: 50, width: 220, height: 350),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil, color: nil,
        direction: .ltr, maxLines: nil, alignment: .start, verticalAnchor: nil), in: view)
    try insertTextForTest("right to left",
      bounds: TextAnnotationBounds(x: 30, y: 80, width: 80, height: 40),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil, color: nil, direction: .auto,
        maxLines: nil, alignment: .start, verticalAnchor: nil), in: view)
    view.textDirection = .auto
    try insertTextForTest("resolved app direction",
      bounds: TextAnnotationBounds(x: 0, y: 140, width: 100, height: 260),
      options: nil, in: view)

    let annotations = try XCTUnwrap(view.viewerDocument?.activePage.history
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

  func testRejectedDraftWritePreservesTextFormattingAndSelection() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let original = try insertTextForTest("Before",
      bounds: TextAnnotationBounds(x: 50, y: 80, width: 200, height: 80),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: 16, color: "#000000",
        direction: .ltr, maxLines: 1, alignment: .start, verticalAnchor: .top), in: view)
    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: original.bounds.midX, y: original.bounds.midY)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.selectedRange = NSRange(location: 2, length: 1)
    let font = editor.font
    let color = editor.textColor
    let selection = editor.selectedRange
    let text = HybridTextHandle(owner: view, generation: view.documentCoordinator.generation,
      pageID: try XCTUnwrap(view.viewerDocument?.activePageID), textID: Double(original.id))
    let options = TextAnnotationOptions(untracked: nil, font: nil, fontSize: 24, color: "#ff0000",
      direction: .rtl, maxLines: 1, alignment: .center, verticalAnchor: .bottom)
    let invalidOptions = TextAnnotationOptions(untracked: nil, font: nil, fontSize: 24, color: "#ff0000",
      direction: .rtl, maxLines: -1, alignment: .center, verticalAnchor: .bottom)
    XCTAssertThrowsError(try text.setValue(text: "first\nsecond", options: invalidOptions)) {
      XCTAssertTrue($0.localizedDescription.hasPrefix("invalid_text_options"))
    }
    XCTAssertEqual(editor.text, "Before")
    XCTAssertEqual(editor.font, font)
    XCTAssertEqual(editor.textColor, color)
    XCTAssertEqual(editor.textAlignment, .left)
    XCTAssertEqual(editor.selectedRange, selection)
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first, original)
    try text.setValue(text: "After", options: options)
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertEqual(try text.getValue(), "After")
    overlay.finishForLifecycle()
    let committed = try XCTUnwrap(view.viewerDocument?.activePage.history.content.textAnnotations.first)
    XCTAssertEqual(committed.text, "After")
    XCTAssertEqual(committed.fontSize, 24)
    XCTAssertEqual(committed.textColor, "#ff0000")
    XCTAssertTrue(committed.isRTL)
  }

  func testProgrammaticTextKeepsCompleteLinesAndVerticalAnchorMetadata() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }

    try insertTextForTest(
      "first line\nsecond line\nthird line",
      bounds: TextAnnotationBounds(x: 80, y: 180, width: 200, height: 100),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil, color: nil, direction: .ltr,
        maxLines: 2, alignment: .start, verticalAnchor: .bottom), in: fixture.view)
    let annotation = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history
      .content.textAnnotations.first)
    let flowBounds = try XCTUnwrap(annotation.flowBounds)
    XCTAssertEqual(flowBounds.minX, 80, accuracy: 0.01)
    XCTAssertEqual(flowBounds.maxX, 280, accuracy: 0.01)
    XCTAssertEqual(flowBounds.minY, 180, accuracy: 0.01)
    XCTAssertEqual(flowBounds.maxY, 280, accuracy: 0.01)
    XCTAssertEqual(annotation.maxLines, 2)
    XCTAssertEqual(annotation.verticalAnchor, .bottom)
    XCTAssertEqual(annotation.bounds.maxY, flowBounds.maxY, accuracy: 0.01)
    let visibleLines = InkSignPdfTextRenderer.positionedLines(
      annotation, pageSize: fixture.view.activePageSize(), color: .black).lines
    XCTAssertEqual(visibleLines.map(\.text), ["first line", "second line"])

    let lineHeight = annotation.bounds.height / CGFloat(visibleLines.count)
    try insertTextForTest(
      "only visible line\nhidden second line",
      bounds: TextAnnotationBounds(x: 20, y: 20, width: 160,
                                    height: Double(lineHeight + 0.1)),
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: nil, color: nil, direction: .ltr,
        maxLines: 2, alignment: .start, verticalAnchor: .top), in: fixture.view)
    let heightLimited = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history
      .content.textAnnotations.last)
    XCTAssertLessThanOrEqual(heightLimited.bounds.height, lineHeight + 0.01)
    XCTAssertGreaterThan(heightLimited.bounds.height, 0)
    XCTAssertEqual(heightLimited.maxLines, 2)
    XCTAssertEqual(InkSignPdfTextRenderer.positionedLines(
      heightLimited, pageSize: fixture.view.activePageSize(), color: .black).lines.map(\.text),
      ["only visible line"])

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
    let options = TextModeOptions(font: nil, direction: .ltr,
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
    let anchoredBottom = textContainerFrame(editor, in: overlay).maxY
    editor.insertText("First line\nSecond line")
    XCTAssertEqual(editor.text, "First line\nSecond line")
    XCTAssertEqual(textContainerFrame(editor, in: overlay).maxY, anchoredBottom, accuracy: 0.01)

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
    XCTAssertEqual(textContainerFrame(editor, in: overlay).maxY, anchoredBottom, accuracy: 0.01)

    overlay.finishForLifecycle()
    let annotation = try XCTUnwrap(view.viewerDocument?.activePage.history.content
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
    let reopened = try XCTUnwrap(view.viewerDocument?.activePage.history.content
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
      font: nil,
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
    let annotation = try XCTUnwrap(view.viewerDocument?.activePage.history.content
      .textAnnotations.first)
    XCTAssertNotNil(annotation.flowBounds)
    XCTAssertTrue(annotation.autoWidth)
    XCTAssertTrue(annotation.autoHeight)
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
      font: nil,
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

    view.textDirection = .rtl
    try view.setMode(mode: .view, options: nil)
    let page = try documentPage(view)
    let targetID = try XCTUnwrap(view.viewerDocument?.activePage.history.content.textAnnotations.last?.id)
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
      fontSize = try page.adjustTextSize(id: Double(targetID), delta: 1)
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
    let resizedAnnotation = try XCTUnwrap(
      view.viewerDocument?.activePage.history.content.textAnnotations.first { $0.id == targetID })
    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: resizedAnnotation.bounds.midX,
                                               y: resizedAnnotation.bounds.midY)))
    let resizedEditor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(resizedEditor.text, originalText)
    XCTAssertEqual(resizedEditor.selectedRange.location, (originalText as NSString).length)

    for expectedText in [String(originalText.dropLast()), afterTwoBackspaces] {
      resizedEditor.deleteBackward()
      XCTAssertEqual(resizedEditor.text, expectedText)
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
    view.textDirection = .ltr
    try view.setMode(mode: .text, options: TextModeOptions(
      font: nil,
      direction: nil,
      width: nil,
      height: nil,
      maxLines: 2,
      alignment: .start,
      verticalAnchor: nil, x: nil, y: nil, zoom: nil))
    view.textDirection = .rtl

    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 180, y: 100)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("direction snapshot")
    overlay.finishForLifecycle()

    let annotation = try XCTUnwrap(view.viewerDocument?.activePage.history.content
      .textAnnotations.first)
    XCTAssertFalse(annotation.isRTL)
    XCTAssertNotNil(annotation.flowBounds)
    XCTAssertTrue(annotation.autoWidth)
    XCTAssertTrue(annotation.autoHeight)
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
    let reopened = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history
      .content.textAnnotations.first)
    XCTAssertTrue(reopened.isRTL)
  }

  func testShortTextUsesItsLaidOutWidthInBothDirections() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    for (direction, value) in [(TextDirection.ltr, "text"), (.rtl, "שלום")] {
      fixture.view.textDirection = direction
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

  func testManualFlowCapacityUsesLogicalAlignment() {
    let cases: [(Bool, InkSignPdfTextAlignment, CGFloat, CGFloat)] = [
      (false, .start, 120, 300), (true, .start, 0, 120),
      (false, .end, 0, 120), (true, .end, 120, 300),
      (false, .center, 0, 240), (true, .center, 0, 240),
    ]
    for (rtl, alignment, left, right) in cases {
      let flow = InkSignPdfTextBoxGeometry.manualFlow(tap: CGPoint(x: 120, y: 100),
        width: nil, height: nil, pageSize: CGSize(width: 300, height: 400),
        isRTL: rtl, alignment: alignment, verticalAnchor: .top)
      XCTAssertEqual(flow.minX, left)
      XCTAssertEqual(flow.maxX, right)
    }
  }

  func testManualGrowthKeepsLogicalHorizontalAndVerticalEdges() throws {
    let cases: [(Bool, TextAlignment, TextVerticalAnchor)] = [
      (false, .start, .top), (true, .start, .top),
      (false, .center, .top), (false, .start, .bottom),
    ]
    for (rtl, alignment, vertical) in cases {
      let fixture = makeFixture(pageCount: 1)
      defer { fixture.view.dispose(); fixture.window.isHidden = true }
      let overlay = fixture.view.textInteractionOverlay
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation,
        options: TextModeOptions(font: nil, direction: rtl ? .rtl : .ltr,
          width: nil, height: nil, maxLines: nil, alignment: alignment,
          verticalAnchor: vertical, x: nil, y: nil, zoom: nil))
      let tap = CGPoint(x: 150, y: 140)
      XCTAssertTrue(overlay.routePlacementTap(at: tap))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      for value in ["A", "A longer line", "First\nSecond\nThird", "A"] {
        editor.text = value
        overlay.textViewDidChange(editor)
        let transform = try XCTUnwrap(fixture.view.pageToOverlayTransform)
        let frame = editor.frame.applying(transform.inverted())
        let right = (alignment == .start && rtl) || (alignment == .end && !rtl)
        XCTAssertEqual(alignment == .center ? frame.midX : right ? frame.maxX : frame.minX,
          tap.x, accuracy: 1)
        XCTAssertEqual(vertical == .bottom ? frame.maxY : frame.minY, tap.y, accuracy: 1)
      }
    }
  }

  func testIndependentDimensionsRetainAdmissionAndIntentAfterCommit() throws {
    let dimensions: [(Double?, Double?)] = [(70, nil), (nil, 45), (70, 45), (nil, nil)]
    for (width, height) in dimensions {
      let fixture = makeFixture(pageCount: 1)
      defer { fixture.view.dispose(); fixture.window.isHidden = true }
      let overlay = fixture.view.textInteractionOverlay
      try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation,
        options: TextModeOptions(font: nil, direction: .ltr,
          width: width, height: height, maxLines: 5,
          alignment: .start, verticalAnchor: .top, x: nil, y: nil, zoom: nil))
      XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 100)))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      editor.insertText("First")
      XCTAssertEqual(editor.text, "First")
      if height != nil {
        editor.insertText("\nSecond\nThird\nFourth")
        XCTAssertEqual(editor.text, "First", "Height is a ceiling even when maxLines permits five")
      }
      if let width { XCTAssertEqual(editor.bounds.width, CGFloat(width), accuracy: 1) }
      overlay.finishForLifecycle()
      let saved = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history.content.textAnnotations.first)
      XCTAssertEqual(saved.autoWidth, width == nil)
      XCTAssertEqual(saved.autoHeight, height == nil)
      let page = try XCTUnwrap(fixture.view.viewerDocument?.activePage)
      let context = InkSignPdfCorePageContext(generation: fixture.view.documentCoordinator.generation, pageID: page.id)
      try fixture.view.documentCore.undo(context)
      XCTAssertTrue(page.history.content.textAnnotations.isEmpty)
      try fixture.view.documentCore.redo(context)
      XCTAssertEqual(page.history.content.textAnnotations.first, saved)
      let transform = try XCTUnwrap(fixture.view.pageToOverlayTransform)
      XCTAssertTrue(overlay.routeTap(at: CGPoint(x: saved.bounds.midX, y: saved.bounds.midY).applying(transform)))
      let reopened = try XCTUnwrap(textEditor(in: overlay))
      XCTAssertEqual(reopened.text, "First")
      XCTAssertEqual(reopened.frame.applying(transform.inverted()).minY, 100, accuracy: 1)
      if let width { XCTAssertEqual(reopened.bounds.width, CGFloat(width), accuracy: 1) }
    }
  }

  func testSnappedPlacementKeepsTextContainerBottomOnRuleDuringGrowth() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)
    try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.minX, 150, accuracy: 0.001)
    XCTAssertEqual(textContainerFrame(editor, in: overlay).maxY, rule.y, accuracy: 0.001)
    editor.text = "A note that grows above the selected rule while it is edited"
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    overlay.textViewDidChange(editor)
    XCTAssertGreaterThan(editor.frame.height, 16)
    XCTAssertEqual(textContainerFrame(editor, in: overlay).maxY, rule.y, accuracy: 0.001)
    XCTAssertEqual(editor.frame.minX, 150, accuracy: 0.001)
  }

  func testExplicitTopOverridesRuleSnapDefault() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
    try cachePlacementRules([.init(minX: 40, maxX: 260, y: 200)], overlay: overlay,
      generation: generation, pageID: pageID)
    try overlay.armPlacement(generation: generation,
      options: TextModeOptions(font: nil, direction: .ltr, width: nil, height: nil,
        maxLines: nil, alignment: .start, verticalAnchor: .top, x: nil, y: nil, zoom: nil))
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 195)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    for value in ["First", "First\nSecond", "First"] {
      editor.text = value
      overlay.textViewDidChange(editor)
      XCTAssertEqual(editor.frame.minY, 200, accuracy: 1)
      XCTAssertEqual(editor.text, value)
    }
  }

  func testRuleSnapUsesTheSameScreenDistanceAtDifferentZoomLevels() throws {
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 200)

    func placementIsSnapped(zoom: CGFloat, screenDistance: CGFloat) throws -> Bool {
      let fixture = makeFixture(pageCount: 1)
      defer { fixture.view.dispose(); fixture.window.isHidden = true }
      let overlay = fixture.view.textInteractionOverlay
      let generation = fixture.view.documentCoordinator.generation
      let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
      let transform = CGAffineTransform(scaleX: zoom, y: zoom)
      fixture.view.pageToOverlayTransform = transform
      try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
      try overlay.armPlacement(generation: generation)

      let point = CGPoint(x: 80 * zoom, y: rule.y * zoom - screenDistance)
      XCTAssertTrue(overlay.routePlacementTap(at: point))
      let editor = try XCTUnwrap(textEditor(in: overlay))
      let presentedTransform = try XCTUnwrap(fixture.view.pageToOverlayTransform)
      let textFrame = textContainerFrame(editor, in: overlay)
      let bottom = CGPoint(x: textFrame.midX, y: textFrame.maxY)
        .applying(presentedTransform.inverted())
      return abs(bottom.y - rule.y) < 0.001
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
    let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
    let rule = InkSignPdfPlacementRule(minX: 40, maxX: 260, y: 20)
    let tap = CGPoint(x: 150, y: 40)
    try cachePlacementRules([rule], overlay: overlay, generation: generation, pageID: pageID)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: tap))

    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.minX, tap.x, accuracy: 0.001)
    XCTAssertEqual(textContainerFrame(editor, in: overlay).minY,
                   tap.y,
                   accuracy: 0.001)
    XCTAssertNotEqual(textContainerFrame(editor, in: overlay).maxY, rule.y)
  }

  func testEmptyPlacementRuleResultLeavesOrdinaryPlacementAvailable() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
    try cachePlacementRules([], overlay: overlay, generation: generation, pageID: pageID)
    let tap = CGPoint(x: 150, y: 140)
    try overlay.armPlacement(generation: generation)
    XCTAssertTrue(overlay.routePlacementTap(at: tap))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    XCTAssertEqual(editor.frame.minX, tap.x, accuracy: 0.001)
    XCTAssertEqual(textContainerFrame(editor, in: overlay).minY,
                   tap.y,
                   accuracy: 0.001)
  }

  func testPlacementUsesOrdinaryFallbackUntilCurrentScanCompletesAndReusesResults() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    let generation = fixture.view.documentCoordinator.generation
    let pageID = try XCTUnwrap(fixture.view.viewerDocument?.activePage.id)
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
    XCTAssertEqual(textContainerFrame(editor, in: overlay).minY,
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
    XCTAssertEqual(textContainerFrame(editor, in: overlay).maxY, nearbyRule.y, accuracy: 0.001)
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

    let secondPage = try XCTUnwrap(fixture.view.viewerDocument?.document.page(at: 1))
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

    let firstPage = try XCTUnwrap(fixture.view.viewerDocument?.document.page(at: 0))
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
    XCTAssertEqual(textContainerFrame(editor, in: overlay).minY,
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
    let history = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history)
    let zoom = fixture.view.documentView.scaleFactor

    fixture.view.interaction.viewport.panViewport(by: CGPoint(x: -40, y: 30))

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
    let state = try XCTUnwrap(fixture.view.viewerDocument)
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
      try InkSignPdfPdfiumExporter.write(sourceURL: state.workingURL,
                                         pages: [snapshot],
                                         outputURL: output,
                                         validatePDFKit: true)
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
    XCTAssertTrue(page.annotations.isEmpty, "Module text is embedded page content")
    let extracted = page.string ?? ""
    for expected in [latin, rtl] {
      XCTAssertTrue(extracted.contains(expected.text), "Extracted PDF text: \(extracted)")
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
      guard let textError = error as? TextError,
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
        !view.interaction.viewport.motion.isRunning
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
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first?.text, "draft")
    XCTAssertNil(textEditor(in: overlay))

    try view.setMode(mode: .text, options: TextModeOptions(
      font: nil, direction: nil, width: nil, height: nil, maxLines: 1,
      alignment: nil, verticalAnchor: nil, x: nil, y: nil, zoom: nil))
    try place()
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)

    try view.setMode(mode: .text, options: TextModeOptions(
      font: nil, direction: nil, width: nil, height: nil, maxLines: nil,
      alignment: nil, verticalAnchor: nil, x: 150, y: 200, zoom: 2))
    XCTAssertEqual(try view.getViewport().zoom, 3, accuracy: 0.01)
    try place()
    XCTAssertEqual(try view.getViewport().zoom, 2, accuracy: 0.01)

    try awaitModeChange(view.setMode(mode: .view, options: nil).setViewport(options: ViewportOptions(x: nil, y: nil, zoom: nil)))
    let fittedZoom = try view.getViewport().zoom
    try awaitModeChange(view.setMode(mode: .ink, options: nil).setViewport(options: ViewportOptions(x: nil, y: nil, zoom: 3)))
    try view.setMode(mode: .text, options: TextModeOptions(
      font: nil, direction: nil, width: nil, height: nil, maxLines: nil,
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
    XCTAssertEqual(fixture.view.viewerDocument?.activePage.history.content.textAnnotations.count, 0)
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
    XCTAssertTrue(fixture.view.viewerDocument?.activePage.history.content.isEmpty == true)
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
    let annotations = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].text, "signed")
    XCTAssertEqual(fixture.view.viewerDocument?.activePage.history.undoStack.map(\.type), [.textCreate])
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
    fixture.view.interaction.setBaseMode(ink: true)
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

  func testPlacementCancelsOnDocumentDetachAndDisposal() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay

    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    let document = fixture.view.document
    fixture.view.document = nil
    XCTAssertFalse(overlay.hasPendingPlacement())
    XCTAssertNil(fixture.view.viewerDocument)
    XCTAssertNil(fixture.view.documentView.document)
    XCTAssertNotNil(document)

    let disposalFixture = makeFixture(pageCount: 1)
    defer { disposalFixture.window.isHidden = true }
    let disposalOverlay = disposalFixture.view.textInteractionOverlay
    try disposalOverlay.armPlacement(generation: disposalFixture.view.documentCoordinator.generation)
    disposalFixture.view.dispose()
    XCTAssertFalse(disposalOverlay.hasPendingPlacement())
  }

  func testRTLTextKeepsLogicalStartAndTopOnCommit() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    fixture.view.textDirection = .rtl
    let placementPoint = CGPoint(x: 180, y: 140)
    try overlay.armPlacement(generation: fixture.view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: placementPoint))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.text = "שלום"
    overlay.textViewDidChange(editor)

    _ = overlay.routeTap(at: CGPoint(x: 10, y: 390))

    let annotations = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history.content.textAnnotations)
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations[0].bounds.maxX, placementPoint.x, accuracy: 0.001)
    XCTAssertEqual(annotations[0].bounds.minY,
                   placementPoint.y,
                   accuracy: 0.001)
  }

  func testLiveEditorLayoutKeepsCaretVisibleAcrossWrappedTextDeletionAndFontChange() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let text = "Invoice אבג 123 — العربية 🖋️ with a long line that wraps\nSecond line"
    let bounds = TextAnnotationBounds(x: 20, y: 100, width: 250, height: 180)
    let annotation = try insertTextForTest(text, bounds: bounds,
      options: TextAnnotationOptions(untracked: nil, font: nil, fontSize: 16,
        color: nil, direction: .auto, maxLines: 0, alignment: .start, verticalAnchor: .top),
      in: view)
    let page = try documentPage(view)
    XCTAssertEqual(try page.adjustTextSize(id: Double(annotation.id), delta: 1), 17, accuracy: 0.001)
    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: annotation.bounds.midX,
                                               y: annotation.bounds.midY)))
    let editor = try XCTUnwrap(textEditor(in: overlay))

    XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 17, accuracy: 0.001)
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
    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(editor.isFirstResponder)
    overlay.finishForLifecycle()
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertTrue(view.viewerDocument!.activePage.history.content.textAnnotations.isEmpty)
  }

  func testLiveEditorUsesFinalTextContainerWidthForLongLTRAndRTLLines() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    let overlay = fixture.view.textInteractionOverlay
    for (isRTL, direction) in [(false, TextDirection.ltr), (true, TextDirection.rtl)] {
      fixture.view.textDirection = direction
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
      let draft = try XCTUnwrap(fixture.view.viewerDocument?.activePage
        .history.content.textAnnotations.first { $0.text == editor.text })
      let committedText = editor.text
      overlay.finishForLifecycle()
      let annotation = try XCTUnwrap(fixture.view.viewerDocument?.activePage
        .history.content.textAnnotations.first { $0.text == committedText })
      XCTAssertEqual(annotation, draft, "Submitting preserves stored placement independently of native caret padding")
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

  func testOutsideTapDeselectsAddedTextWhileDraggingRetainsSelection() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let annotation = try insertTextForTest("note",
      bounds: TextAnnotationBounds(x: 60, y: 80, width: 140, height: 60), options: nil, in: view)
    let start = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: start, selectedOnly: false))
    XCTAssertEqual(overlay.selectedText?.textId, Double(annotation.id))

    let destination = CGPoint(x: start.x + 20, y: start.y + 15)
    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.changed, at: destination, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.ended, at: destination, selectedOnly: true))
    XCTAssertEqual(overlay.selectedText?.textId, Double(annotation.id))

    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: 10, y: 390)))
    XCTAssertNil(overlay.selectedText)
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first?.text, "note")
  }

  func testBackspaceClearingNewTextKeepsEditorUntilSubmission() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 150, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("X")
    editor.deleteBackward()

    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(editor.isFirstResponder)
    XCTAssertGreaterThan(editor.bounds.width, 0)
    XCTAssertGreaterThan(editor.bounds.height, 0)
    editor.insertText("again\nagain")
    XCTAssertEqual(editor.text, "again\nagain")
    XCTAssertLessThanOrEqual(editor.caretRect(for: editor.endOfDocument).maxY, editor.bounds.height + 1)
    editor.selectedRange = NSRange(location: 0, length: (editor.text as NSString).length)
    editor.deleteBackward()
    XCTAssertTrue(textEditor(in: overlay) === editor)
    overlay.finishForLifecycle()
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertFalse(editor.isFirstResponder)
    XCTAssertNil(overlay.selectedText)
    XCTAssertTrue(view.viewerDocument!.activePage.history.content.textAnnotations.isEmpty)
    XCTAssertFalse(try documentPage(view).getState().canUndo)

    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 80, y: 180)))
    let nextEditor = try XCTUnwrap(textEditor(in: overlay))
    nextEditor.insertText("next")
    XCTAssertEqual(nextEditor.text, "next")
    overlay.finishForLifecycle()
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first?.text, "next")
  }

  func testBackspaceClearingCommittedTextKeepsEditorUntilSubmissionAndCanBeUndone() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    let original = try insertTextForTest("Z",
      bounds: TextAnnotationBounds(x: 50, y: 80, width: 120, height: 60), options: nil, in: view)
    XCTAssertTrue(overlay.routeTap(at: CGPoint(x: original.bounds.midX, y: original.bounds.midY)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.selectedRange = NSRange(location: 1, length: 0)
    editor.deleteBackward()

    XCTAssertTrue(textEditor(in: overlay) === editor)
    XCTAssertTrue(editor.isFirstResponder)
    XCTAssertGreaterThan(editor.bounds.width, 0)
    XCTAssertGreaterThan(editor.bounds.height, 0)
    overlay.finishForLifecycle()
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertFalse(editor.isFirstResponder)
    XCTAssertNil(overlay.selectedText)
    XCTAssertTrue(view.viewerDocument!.activePage.history.content.textAnnotations.isEmpty)
    let page = try documentPage(view)
    try page.undo()
    XCTAssertEqual(view.viewerDocument?.activePage.history.content.textAnnotations.first, original)
    XCTAssertNil(textEditor(in: overlay))
  }

  func testEditingTapPlacesCaretAndBorderLongPressBeginsDragging() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let overlay = view.textInteractionOverlay
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 100, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("abcdef")
    let start = editor.caretRect(for: editor.beginningOfDocument)
    XCTAssertTrue(overlay.routeTap(at: editor.convert(CGPoint(x: start.midX, y: start.midY), to: overlay)))
    XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
    XCTAssertTrue(textEditor(in: overlay) === editor)

    let border = editor.convert(CGPoint(x: -2, y: editor.bounds.midY), to: overlay)
    XCTAssertTrue(overlay.routeDrag(.began, at: border, selectedOnly: false))
    XCTAssertNil(textEditor(in: overlay))
    XCTAssertTrue(overlay.routeDrag(.changed, at: CGPoint(x: border.x + 20, y: border.y + 10), selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: CGPoint(x: border.x + 20, y: border.y + 10), selectedOnly: false))
    XCTAssertNotNil(overlay.selectedText)
  }

  func testLiveEditorPresentationContainsNativeCaretForMultilineRTLText() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    view.textDirection = .rtl
    let overlay = view.textInteractionOverlay
    try overlay.armPlacement(generation: view.documentCoordinator.generation)
    XCTAssertTrue(overlay.routePlacementTap(at: CGPoint(x: 200, y: 140)))
    let editor = try XCTUnwrap(textEditor(in: overlay))
    editor.insertText("שלום   \nעולם   ")
    for position in [editor.beginningOfDocument, editor.endOfDocument] {
      let caret = editor.caretRect(for: position)
      XCTAssertGreaterThanOrEqual(caret.minY, -1)
      XCTAssertLessThanOrEqual(caret.maxY, editor.bounds.height + 1)
    }
    XCTAssertEqual(editor.text, "שלום   \nעולם   ")
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
    let history = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history)

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
    let history = try XCTUnwrap(fixture.view.viewerDocument?.activePage.history)

    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.ended, at: start, selectedOnly: false))
    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.changed, at: destination, selectedOnly: true))
    XCTAssertTrue(overlay.routeDrag(.cancelled, at: destination, selectedOnly: true))
    XCTAssertEqual(history.undoStack.map(\.type), [.textCreate])
    XCTAssertEqual(history.content.textAnnotations.first, original)

    XCTAssertTrue(overlay.routeDrag(.began, at: start, selectedOnly: true))
    XCTAssertTrue(fixture.view.viewerDocument!.selectPage(at: 1))
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

  func testSelectedTextHandleSurvivesViewerDisposalAndRejectsOwnerClose() throws {
    let fixture = makeFixture(pageCount: 2)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let owner = try attachedDocument(view)
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
    XCTAssertTrue(view.viewerDocument!.selectPage(at: 1))
    try text.setValue(text: "updated", options: nil)
    let document = try XCTUnwrap(view.viewerDocument)
    XCTAssertEqual(document.pages[0].history.content.textAnnotations.first?.text, "updated")
    XCTAssertTrue(document.pages[1].history.content.textAnnotations.isEmpty)
    try text.setValue(text: "", options: nil)
    XCTAssertEqual(try text.getValue(), "")
    XCTAssertTrue(document.pages[0].history.content.textAnnotations.isEmpty)
    view.dispose()
    XCTAssertEqual(try text.getValue(), "")
    try awaitTestPromise(owner.close())
    XCTAssertThrowsError(try text.getValue())
  }

  func testTextTargetIDsAreMonotonicAndUnique() throws {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let first = try insertTextForTest("first",
      bounds: TextAnnotationBounds(x: 20, y: 50, width: 80, height: 40),
      options: nil, in: fixture.view)
    let second = try insertTextForTest("second",
      bounds: TextAnnotationBounds(x: 180, y: 200, width: 80, height: 40),
      options: nil, in: fixture.view)

    XCTAssertGreaterThan(first.id, 0)
    XCTAssertGreaterThan(second.id, first.id)
    XCTAssertEqual(fixture.view.viewerDocument?.activePage.history.content.textAnnotations.count, 2)
  }

  /// Native caret padding may expand the editor beyond its page-space text anchor.
  private func textContainerFrame(_ editor: UITextView, in overlay: UIView) -> CGRect {
    editor.convert(editor.bounds.inset(by: editor.textContainerInset), to: overlay)
  }

}
