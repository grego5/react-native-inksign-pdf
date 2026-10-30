import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

/// PDFKit boundary integration. Real press/pinch/menu competition also needs device acceptance.
final class SourceTextSelectionInteractionTests: XCTestCase, InkSignViewTestSupport {
  override func setUp() {
    super.setUp()
    executionTimeAllowance = 60
  }

  func testWordPathCopyUsesNativeActionWithoutChangingHistoryOrAnnotationSelection() throws {
    let fixture = makeFixture(pageCount: 1, sourceText: "A B C")
    let clipboard = configureCopyPasteboard(in: fixture.view)
    defer {
      fixture.view.dispose()
      fixture.window.isHidden = true
      UIPasteboard.remove(withName: clipboard.name)
    }
    let view = fixture.view
    let page = try XCTUnwrap(view.viewerDocument?.activePage)
    let words = page.prepared.sourceWords.words
    XCTAssertEqual(words.map(\.text), ["A", "B", "C"])
    let revision = page.history.revision
    let dirty = view.documentCoordinator.isDirty
    var annotationEvents = 0
    view.onTextSelectionChange = { _ in annotationEvents += 1 }
    let baselineEvents = annotationEvents
    let controller = view.sourceTextSelection
    controller.beginSelection(at: try point(words[1], in: view))
    controller.visit(try [point(words[2], in: view), point(words[1], in: view), point(words[0], in: view)])
    XCTAssertEqual(controller.selectedCopyText(), "A B")
    let configuration = try XCTUnwrap(controller.finishSelection())
    perform(try copyAction(configuration, in: view))
    XCTAssertEqual(clipboard.string, "A B")
    XCTAssertNil(controller.selectedCopyText())
    XCTAssertEqual(page.history.revision, revision)
    XCTAssertEqual(view.documentCoordinator.isDirty, dirty)
    XCTAssertEqual(annotationEvents, baselineEvents)
    XCTAssertNil(textEditor(in: view.textInteractionOverlay))
  }

  func testRetiredCopyActionCannotCopyOrClearReplacementSelection() throws {
    NSLog("Source-selection copy lifecycle: create fixture")
    let fixture = makeFixture(pageCount: 1, sourceText: "A B C")
    NSLog("Source-selection copy lifecycle: create private pasteboard")
    let clipboard = configureCopyPasteboard(in: fixture.view)
    defer {
      NSLog("Source-selection copy lifecycle: dispose fixture")
      fixture.view.dispose()
      fixture.window.isHidden = true
      UIPasteboard.remove(withName: clipboard.name)
    }
    let view = fixture.view
    let words = try XCTUnwrap(view.viewerDocument?.activePage.prepared.sourceWords.words)
    let controller = view.sourceTextSelection
    controller.beginSelection(at: try point(words[1], in: view))
    NSLog("Source-selection copy lifecycle: create original action")
    let retired = try copyAction(XCTUnwrap(controller.finishSelection()), in: view)
    NSLog("Source-selection copy lifecycle: replace selection")
    _ = try view.setMode(mode: .view, options: nil)
    NSLog("Source-selection copy lifecycle: begin replacement selection")
    controller.beginSelection(at: try point(words[2], in: view))
    NSLog("Source-selection copy lifecycle: set clipboard sentinel")
    clipboard.string = "unchanged"
    NSLog("Source-selection copy lifecycle: invoke retired action")
    perform(retired)
    NSLog("Source-selection copy lifecycle: verify retired action")
    XCTAssertEqual(clipboard.string, "unchanged")
    XCTAssertEqual(controller.selectedCopyText(), "C")
    NSLog("Source-selection copy lifecycle: create replacement action")
    perform(try copyAction(XCTUnwrap(controller.finishSelection()), in: view))
    NSLog("Source-selection copy lifecycle: verify replacement action")
    XCTAssertEqual(clipboard.string, "C")
    XCTAssertNil(controller.selectedCopyText())
  }

  func testPresentationRetirementRemovesHighlightsAndInvalidatesMenu() throws {
    let retirements: [(String, (ViewerCanvas) throws -> Void)] = [
      ("mode replacement", { _ = try $0.setMode(mode: .view, options: nil) }),
      ("page navigation", { _ = try $0.switchPage(to: 1) }),
      ("rotation", { view in
        let owner = try self.attachedDocument(view)
        try self.awaitTestPromise(owner.rotatePage(index: 0, degrees: 90))
      }),
      ("structural suspension", { $0.interaction.suspendStructural() }),
      ("window detach", { $0.container.removeFromSuperview() }),
      ("document detach", { $0.releaseAttachment() }),
      ("disposal", { $0.dispose() }),
    ]
    for (name, retire) in retirements {
      let fixture = makeFixture(sourceText: "A B C")
      defer { fixture.view.dispose(); fixture.window.isHidden = true }
      let view = fixture.view
      let overlay = view.overlayProvider.overlayView
      let children = Set(overlay.subviews.map(ObjectIdentifier.init))
      let word = try XCTUnwrap(view.viewerDocument?.activePage.prepared.sourceWords.words.first)
      view.sourceTextSelection.beginSelection(at: try point(word, in: view))
      let highlight = try XCTUnwrap(overlay.subviews.first { !children.contains(ObjectIdentifier($0)) })
      let configuration = try XCTUnwrap(view.sourceTextSelection.finishSelection())
      let menuInteraction = try XCTUnwrap(view.overlayProvider.overlayView.subviews.flatMap(\.interactions).compactMap { $0 as? UIEditMenuInteraction }.first)
      try retire(view)
      XCTAssertNil(view.sourceTextSelection.selectedCopyText(), name)
      XCTAssertNil(highlight.superview, name)
      XCTAssertNil(view.sourceTextSelection.editMenuInteraction(menuInteraction,
        menuFor: configuration, suggestedActions: []), name)
    }
  }

  func testImageOnlyPageDoesNotCreateSelectionOrCopyMenu() {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    fixture.view.sourceTextSelection.beginSelection(at: CGPoint(x: 150, y: 200))
    XCTAssertNil(fixture.view.sourceTextSelection.selectedCopyText())
    XCTAssertNil(fixture.view.sourceTextSelection.finishSelection())
    XCTAssertNil(textEditor(in: fixture.view.textInteractionOverlay))
  }

  func testSourceTouchConversionUsesVisibleOriginAtEveryQuarterTurn() throws {
    let fixture = makeFixture(pageCount: 1, cropBox: CGRect(x: 20, y: 30, width: 250, height: 340))
    defer { fixture.view.dispose(); fixture.window.isHidden = true }
    let view = fixture.view
    let owner = try attachedDocument(view)
    let canonical = CGPoint(x: 47, y: 81)
    for rotation in [0, 90, 180, 270] {
      if rotation != 0 {
        try awaitTestPromise(owner.rotatePage(index: 0, degrees: 90))
        try awaitViewerPageReady(view)
      }
      let state = try XCTUnwrap(view.viewerDocument)
      XCTAssertEqual(state.activePage.geometry.rotation, rotation)
      let pdf = canonical.applying(state.activePage.geometry.canonicalToPDFTransform)
      let rendered = view.documentView.convert(pdf, from: state.activePDFPage)
      let selected = try XCTUnwrap(view.sourceCanonicalPoint(rendered))
      XCTAssertEqual(selected.x, canonical.x, accuracy: 0.001)
      XCTAssertEqual(selected.y, canonical.y, accuracy: 0.001)
    }
  }

  private func point(_ word: InkSignPdfSourceWord, in view: ViewerCanvas) throws -> CGPoint {
    let state = try XCTUnwrap(view.viewerDocument)
    let rect = try XCTUnwrap(word.rectangles.first)
    let canonical = CGPoint(x: rect.midX, y: rect.midY)
    return view.documentView.convert(canonical.applying(state.activePage.geometry.canonicalToPDFTransform),
      from: state.activePDFPage)
  }

  private func configureCopyPasteboard(in view: ViewerCanvas) -> UIPasteboard {
    let pasteboard = UIPasteboard.withUniqueName()
    view.sourceTextSelection.dispose()
    view.sourceTextSelection = InkSignPdfSourceTextSelectionController(owner: view, pasteboard: pasteboard)
    return pasteboard
  }

  private func copyAction(_ configuration: UIEditMenuConfiguration, in view: ViewerCanvas) throws -> UIAction {
    let interaction = try XCTUnwrap(view.overlayProvider.overlayView.subviews.flatMap(\.interactions).compactMap { $0 as? UIEditMenuInteraction }.first)
    let menu = try XCTUnwrap(view.sourceTextSelection.editMenuInteraction(interaction,
      menuFor: configuration, suggestedActions: [UICommand(title: "Copier", action: #selector(UIResponderStandardEditActions.copy(_:)))]))
    let action = try XCTUnwrap(menu.children.compactMap { $0 as? UIAction }.first)
    XCTAssertEqual(action.title, "Copier")
    return action
  }

  private func perform(_ action: UIAction) {
    let button = UIButton(type: .system)
    button.addAction(action, for: .touchUpInside)
    button.sendActions(for: .touchUpInside)
  }
}
