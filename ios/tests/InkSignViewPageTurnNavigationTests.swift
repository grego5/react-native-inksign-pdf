import CoreGraphics
import PDFKit
import NitroModules
import PencilKit
import UIKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewPageTurnNavigationTests: XCTestCase, InkSignViewTestSupport {
  func testPageTurnScaleChangesOnlyDuringLatePull() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -64, y: 0))
    XCTAssertEqual(fixture.view.documentView.transform.a, 1, accuracy: 0.001)

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -120, y: 0))
    XCTAssertLessThan(fixture.view.documentView.transform.a, 1)
    XCTAssertGreaterThan(fixture.view.documentView.transform.a, 0.96)
  }

  func testArmedPageTurnChangesPageExactlyOnce() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testSubthresholdPageTurnSettlesPreviewWithPageBeforeClearing() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    let initialOffset = abs(fixture.view.documentView.transform.tx)

    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertGreaterThan(abs(fixture.view.documentView.transform.tx), 0)

    fixture.animationFactory.lastDriver?.advance(to: 0.35)
    XCTAssertLessThan(abs(fixture.view.documentView.transform.tx), initialOffset)
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)

    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testRetreatBelowDeadZoneUsesIdentityCheckedRestSettlement() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    let activePage = fixture.view.documentCoordinator.document?.activePageIndex

    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -4, y: 0))

    guard case .settling = fixture.view.pageTurnLifecycle.phase else {
      return XCTFail("retreat below the dead zone must settle through the lifecycle")
    }
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePageIndex, activePage)
    fixture.animationFactory.lastDriver?.complete()
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
  }

  func testReversalAndLossOfHorizontalDominanceUseRestSettlement() {
    for translation in [CGPoint(x: 32, y: 0), CGPoint(x: -4, y: 40)] {
      let fixture = makeFixture()
      defer { fixture.window.isHidden = true }
      XCTAssertTrue(beginPull(in: fixture.view))
      fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
      fixture.view.pageTurnLifecycle.pullChanged(translation: translation)

      guard case .settling = fixture.view.pageTurnLifecycle.phase else {
        return XCTFail("invalidated pull must use rest settlement")
      }
      fixture.animationFactory.lastDriver?.complete()
      XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
      XCTAssertEqual(fixture.view.documentCoordinator.document?.activePageIndex, 0)
    }
  }

  func testNewGestureCancelsStalePageTurnSettlement() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    XCTAssertTrue(fixture.view.prepareForEdgeNavigationTouch(at: CGPoint(x: 300, y: 300)))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -24, y: 0))
    let newOffset = abs(fixture.view.documentView.transform.tx)

    XCTAssertNil(staleDriver)
    staleCallback?.advance(to: 0.35)
    XCTAssertEqual(abs(fixture.view.documentView.transform.tx), newOffset, accuracy: 0.0001)
    staleCallback?.complete()
    XCTAssertEqual(abs(fixture.view.documentView.transform.tx), newOffset, accuracy: 0.0001)
    XCTAssertGreaterThan(newOffset, 0)
  }

  func testCompletedSettlementDriverIsReleased() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    beginSubthresholdSettlement(in: fixture.view)
    weak var weakAnimation = fixture.view.pageTurnLifecycle.settlementDriver
    XCTAssertNotNil(weakAnimation)

    fixture.animationFactory.lastDriver?.complete()

    XCTAssertNil(weakAnimation)
    XCTAssertNil(fixture.view.pageTurnLifecycle.settlementDriver)
  }

  func testCancelledSettlementDriverIsReleased() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    beginSubthresholdSettlement(in: fixture.view)
    weak var weakAnimation = fixture.view.pageTurnLifecycle.settlementDriver
    XCTAssertNotNil(weakAnimation)

    fixture.view.pageTurnLifecycle.cancelSettlement()

    XCTAssertNil(weakAnimation)
    XCTAssertNil(fixture.view.pageTurnLifecycle.settlementDriver)
  }

  func testModeChangeCancelsPageTurnSettlementBeforeStaleCallback() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    fixture.view.setInteractionMode(editing: true)
    XCTAssertNil(staleDriver)
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.advance(to: 0.35)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testDisposalCancelsPageTurnSettlementBeforeStaleCallback() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -32, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    XCTAssertFalse(fixture.view.pageTurnLifecycle.previewView.isHidden)
    let staleCallback = fixture.animationFactory.lastCallback
    weak var staleDriver = fixture.animationFactory.lastDriver
    XCTAssertNotNil(staleDriver)

    fixture.view.dispose()
    XCTAssertNil(staleDriver)
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    staleCallback?.advance(to: 0.35)
    XCTAssertTrue(fixture.view.documentView.transform.isIdentity)
    staleCallback?.complete()
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
  }

  func testPageSwitchCompletesAfterRetainedOverlayHandoff() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      if case .failure(let error) = result {
        XCTFail("unexpected page switch failure: \(error)")
      }
    }

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])

    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testOverlayDetachmentAfterCommittedPageTurnDoesNotResettleIt() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }
    XCTAssertTrue(beginPull(in: fixture.view))
    fixture.view.pageTurnLifecycle.pullChanged(translation: CGPoint(x: -180, y: 0))
    fixture.view.pageTurnLifecycle.pullEnded()
    fixture.animationFactory.lastDriver?.complete()

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertTrue(fixture.view.pageTurnLifecycle.previewView.isHidden)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
    let completedSwitchID = fixture.view.pageSwitchRequestID
    XCTAssertFalse(fixture.view.pageTurnLifecycle.pageSwitchReady(switchID: completedSwitchID &+ 1))
    fixture.view.pageTurnLifecycle.pageSwitchCancelled(switchID: completedSwitchID &+ 1)
    fixture.view.pageTurnLifecycle.pageSwitchFailed(switchID: completedSwitchID &+ 1)

    fixture.view.overlayDidEndDisplaying(fixture.view.canvasView, for: fixture.pages[1])
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertTrue(isIdle(fixture.view.pageTurnLifecycle))
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
    XCTAssertEqual(completionCount, 1)
  }

  func testCompletedPageSwitchIgnoresCancellationAndLateOverlayCallback() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    var switchResult: Result<PageInfo, Error>?

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      switchResult = result
    }

    fixture.view.cancelPendingPageSwitch()
    fixture.view.cancelPendingPageSwitch()
    fixture.view.overlayDidDisplay(fixture.view.canvasView, for: fixture.pages[1])

    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(completionCount, 1)
    guard case .success(let pageInfo) = switchResult else {
      return XCTFail("the installed target page should complete successfully")
    }
    XCTAssertEqual(pageInfo.pageIndex, 1)
  }

  func testNewerQueuedPageNavigationPublishesOnlyItsResult() throws {
    let fixture = makeFixture(pageCount: 3)
    defer { fixture.window.isHidden = true }
    var pageChanges = [PageInfo]()
    fixture.view.onPageChange = { pageChanges.append($0) }

    try fixture.view.nextPage()
    try fixture.view.nextPage()
    drainMainQueue()

    XCTAssertEqual(pageChanges.map(\.pageIndex), [1])
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[1])
  }

  func testDocumentReplacementInvalidatesQueuedPageNavigation() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }

    try fixture.view.nextPage()

    fixture.view.beginLoad(
      "",
      zoom: nil,
      focus: nil,
      fitToPage: true,
      promise: Promise<PageInfo>())
    drainMainQueue()

    XCTAssertEqual(completionCount, 0)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(fixture.view.documentView.currentPageID, fixture.pages[0])
  }

  func testDisposalInvalidatesQueuedPageNavigation() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0
    fixture.view.onPageChange = { _ in completionCount += 1 }

    try fixture.view.nextPage()

    fixture.view.dispose()
    fixture.view.dispose()
    drainMainQueue()

    XCTAssertEqual(completionCount, 0)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
  }

}
