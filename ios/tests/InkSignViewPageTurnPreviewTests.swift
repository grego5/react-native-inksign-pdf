import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewPageTurnPreviewTests: XCTestCase, InkSignViewTestSupport {
  func testPageTurnGestureArmsMapsDirectionAndIssuesOneHaptic() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))

    guard let gesture = fixture.view.pageTurnLifecycle.pullingState else {
      return XCTFail("eligible pull should retain gesture state")
    }
    if case .some(.left) = gesture.physicalDirection {} else {
      XCTFail("negative pull should be classified as a leftward gesture")
    }
    XCTAssertEqual(gesture.targetDelta, 1)
    XCTAssertEqual(gesture.progress, 1)
    XCTAssertTrue(gesture.hapticIssued)
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)
    XCTAssertEqual(fixture.view.documentView.transform.a, 0.96, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -80, y: 0))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.pullingState?.hapticIssued == true)
  }

  func testPageTurnGestureCancellationReturnsPresentationToRest() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)
    XCTAssertEqual(fixture.view.documentView.transform.a, 0.96, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullCancelled()

    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("cancellation must remain in settlement until animation completion")
    }
    fixture.animationFactory.lastDriver?.advance(to: 0.35)
    XCTAssertGreaterThan(fixture.view.documentView.transform.a, 0.96)
    XCTAssertLessThanOrEqual(fixture.view.documentView.transform.a, 1)
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testPageTurnGestureMapsBothDirectionsInRTLAndLTR() {
    let cases: [(rtl: Bool, translation: CGFloat, delta: Int)] = [
      (false, 64, -1),
      (false, -64, 1),
      (true, 64, 1),
      (true, -64, -1),
    ]

    for testCase in cases {
      let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
      defer { fixture.window.isHidden = true }
      if testCase.rtl {
        fixture.view.documentView.semanticContentAttribute = .forceRightToLeft
        fixture.window.layoutIfNeeded()
        fixture.view.pageTurnLifecycle.stableContextChanged()
        fixture.previewScheduler.completeAll()
      }
      XCTAssertTrue(beginPull(in: fixture.view))
      fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: testCase.translation, y: 0))

      XCTAssertEqual(fixture.view.pageTurnLifecycle.pullingState?.targetDelta, testCase.delta)
      let physical: InkSignPdfEdgeNavigationPhysicalDirection = testCase.translation >= 0 ? .right : .left
      XCTAssertEqual(InkSignPdfPageNavigationPolicy.pageTurnTargetDelta(for: physical, isRTL: testCase.rtl),
                     testCase.delta)
    }
  }

  func testPageTurnPreviewDirectionSelectsTheSemanticNeighbor() {
    XCTAssertEqual(InkSignPdfPageNavigationPolicy.pageTurnTargetDelta(for: .left, isRTL: false), 1)
    XCTAssertEqual(InkSignPdfPageNavigationPolicy.pageTurnTargetDelta(for: .right, isRTL: false), -1)
    XCTAssertEqual(InkSignPdfPageNavigationPolicy.pageTurnTargetDelta(for: .left, isRTL: true), -1)
    XCTAssertEqual(InkSignPdfPageNavigationPolicy.pageTurnTargetDelta(for: .right, isRTL: true), 1)
  }

  func testPageTurnLifecycleKeepsGestureDataInsidePullingPhase() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("gesture ownership should enter the pulling phase")
    }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
  }

  func testStableContextReconciliationPreservesPullAndSettlementStates() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must not replace an active pull")
    }

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .pulling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must preserve pulled presentation")
    }

    _ = fixture.view.documentCoordinator.nextGeneration()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("changed stable context must settle an active pull")
    }
    fixture.animationFactory.lastDriver?.complete()
    guard case .idle = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("context invalidation settlement must return to idle")
    }
    fixture.previewScheduler.completeAll()

    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("stable layout must preserve rest settlement")
    }
  }

  func testSinglePageLifecycleDoesNotCreatePreviewState() {
    let fixture = makeFixture(pageCount: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(preparedPreview(.right, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.right, in: fixture.view))
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
  }

  func testTouchPreflightAcceptsOneReadyEligibleDirection() throws {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let leftRequest = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("middle page should schedule the left preview")
    }
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.complete(request: leftRequest, image: UIImage())
    XCTAssertNotNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    let pageBounds = try XCTUnwrap(fixture.view.documentView.viewportTransform?.pageFrame)

    XCTAssertTrue(fixture.view.prepareForEdgeNavigationTouch(at: CGPoint(
      x: pageBounds.midX,
      y: pageBounds.midY)))
    guard case .pulling(let transaction) = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("one ready eligible direction should start a pull")
    }
    XCTAssertNotNil(transaction.previews[.left])
    XCTAssertNil(transaction.previews[.right])
  }

  func testRTLPreviewAndCommitUseTheNextPage() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.documentView.semanticContentAttribute = .forceRightToLeft
    fixture.window.layoutIfNeeded()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    fixture.previewScheduler.completeAll()

    XCTAssertEqual(preparedPreview(.right, in: fixture.view)?.key.targetPageIndex, 1)
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: 180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testRepeatedStablePreviewReconciliationSubmitsOneRenderPerDirection() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    let initialSubmissionCount = fixture.previewScheduler.submittedRequests.count

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 1)
    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 1)
    fixture.previewScheduler.completeAll()
    XCTAssertNotNil(preparedPreview(.left, in: fixture.view))
  }

  func testTwoEligibleDirectionsEachRetainOneInFlightRequest() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    let initialSubmissionCount = fixture.previewScheduler.submittedRequests.count

    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 2)
    XCTAssertNotNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertNotNil(renderingRequest(.right, in: fixture.view))
    fixture.previewScheduler.completeNext()
    XCTAssertEqual(fixture.previewScheduler.submittedRequests.count - initialSubmissionCount, 2)
  }

  func testChangingOnePreviewIdentityResubmitsOnlyThatDirection() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let left = renderingRequest(.left, in: fixture.view),
          let right = renderingRequest(.right, in: fixture.view) else {
      return XCTFail("both directions should have an initial request")
    }
    fixture.previewScheduler.complete(request: left, image: UIImage())
    fixture.previewScheduler.complete(request: right, image: UIImage())
    guard let state = fixture.view.documentCoordinator.document else { return XCTFail("fixture state missing") }
    state.pages[2].history.appendText(makeCenteredTextAnnotation(
      id: "preview-left-revision",
      text: "updated",
      fontSize: 16,
      pageSize: state.pages[2].geometry.mediaBox.size))

    fixture.view.pageTurnLifecycle.stableContextChanged()

    XCTAssertNotNil(renderingRequest(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.right, in: fixture.view))
    XCTAssertEqual(preparedPreview(.right, in: fixture.view)?.key, right.key)
  }

  func testStalePreviewCompletionCannotClearNewerRequestAndFailureCanRetry() {
    let fixture = makeFixture(pageCount: 3, activePageIndex: 1)
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let stale = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("initial left request should exist")
    }
    guard let state = fixture.view.documentCoordinator.document else { return XCTFail("fixture state missing") }
    state.pages[2].history.appendText(makeCenteredTextAnnotation(
      id: "preview-stale-revision",
      text: "updated",
      fontSize: 16,
      pageSize: state.pages[2].geometry.mediaBox.size))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let current = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("changed target should submit a replacement request")
    }

    fixture.previewScheduler.complete(request: stale, image: UIImage())
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, current.key)
    XCTAssertNil(preparedPreview(.left, in: fixture.view))

    fixture.previewScheduler.complete(request: current, image: nil)
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    fixture.view.pageTurnLifecycle.stableContextChanged()
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, current.key)
  }

  func testStaleSameKeyPreviewCompletionCannotClearReplacementRequest() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let first = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("initial preview request should exist")
    }

    fixture.view.overlayDidEndDisplaying(fixture.view.canvasView, for: fixture.pages[0])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[0])
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let replacement = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("replacement preview request should exist")
    }
    XCTAssertEqual(first.key, replacement.key)

    fixture.previewScheduler.completeNext(image: nil)
    XCTAssertEqual(renderingRequest(.left, in: fixture.view)?.key, replacement.key)

    fixture.previewScheduler.completeNext(image: UIImage())
    XCTAssertEqual(preparedPreview(.left, in: fixture.view)?.key, replacement.key)
  }


  func testDisposalRejectsDelayedPreviewCompletion() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let request = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("disposal test should have a queued preview")
    }

    fixture.view.dispose()
    fixture.previewScheduler.complete(request: request, image: UIImage())

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testDocumentReplacementRejectsDelayedPreviewCompletion() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.view.pageTurnLifecycle.stableContextChanged()
    guard let request = renderingRequest(.left, in: fixture.view) else {
      return XCTFail("replacement test should have a queued preview")
    }

    _ = fixture.view.documentCoordinator.nextGeneration()
    fixture.view.pageTurnLifecycle.cancelUncommittedTurn()
    fixture.previewScheduler.complete(request: request, image: UIImage())

    XCTAssertNil(preparedPreview(.left, in: fixture.view))
    XCTAssertNil(renderingRequest(.left, in: fixture.view))
  }

  func testPageTurnPreviewUsesFitCenteredTargetFrame() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }

    guard let preview = preparedPreview(.left, in: fixture.view) else {
      return XCTFail("next-page preview should be prepared")
    }
    XCTAssertEqual(preview.frame.midX, fixture.view.documentView.bounds.midX, accuracy: 0.5)
    XCTAssertEqual(preview.frame.midY, fixture.view.documentView.bounds.midY, accuracy: 0.5)
    XCTAssertEqual(preview.key.targetPageIndex, 1)
  }

}
