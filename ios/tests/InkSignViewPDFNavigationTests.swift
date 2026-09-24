import PDFKit
import XCTest
@testable import ReactNativeInkSignPdf

final class InkSignViewPDFNavigationTests: XCTestCase, InkSignViewTestSupport {
  func testPDFViewOwnsNativePagePresentation() {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }

    XCTAssertEqual(fixture.view.documentView.displayMode, .singlePage)
    XCTAssertEqual(fixture.view.documentView.displayDirection, .horizontal)
    XCTAssertTrue(fixture.view.documentView.isUsingPageViewController)
    XCTAssertNotNil(fixture.view.documentView.pageOverlayViewProvider)
    XCTAssertTrue(fixture.view.documentView.isOpaque)
    XCTAssertEqual(fixture.view.documentView.backgroundColor, .white)
  }

  func testCoordinatorFollowsPDFViewPageChanges() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var changes = [PageInfo]()
    fixture.view.onPageChange = { changes.append($0) }

    let page = try XCTUnwrap(fixture.view.documentCoordinator.document?.pages[1].page)
    fixture.view.documentView.go(to: page)
    fixture.view.documentViewDidNavigate(to: page)
    let overlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: page))
    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willDisplayOverlayView: overlay,
                                         for: page)

    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.id, fixture.pages[1])
    XCTAssertEqual(changes.map(\.pageIndex), [1])
    XCTAssertNil(fixture.view.pendingPageSwitchID)
  }

  func testProgrammaticPageChangeUsesPDFViewAndCompletesAfterOverlay() throws {
    let fixture = makeFixture()
    defer { fixture.window.isHidden = true }
    var completionCount = 0

    try fixture.view.switchPage(to: 1) { result in
      completionCount += 1
      if case .failure(let error) = result {
        XCTFail("unexpected page change failure: \(error)")
      }
    }

    let page = try XCTUnwrap(fixture.view.documentCoordinator.document?.activePage.page)
    XCTAssertTrue(fixture.view.documentView.currentPage === page)
    let overlay = try XCTUnwrap(fixture.view.overlayProvider.pdfView(
      fixture.view.documentView,
      overlayViewFor: page))
    fixture.view.overlayProvider.pdfView(fixture.view.documentView,
                                         willDisplayOverlayView: overlay,
                                         for: page)

    XCTAssertEqual(completionCount, 1)
    XCTAssertNil(fixture.view.pendingPageSwitchID)
    XCTAssertEqual(fixture.view.documentCoordinator.document?.activePage.id, fixture.pages[1])
  }
}
