import CoreGraphics

enum InkSignPdfEdgeNavigationPhysicalDirection: Hashable {
  case left
  case right
}

struct InkSignPdfEdgeNavigationGesture {
  let previousEligible: Bool
  let nextEligible: Bool
  let isRTL: Bool
  let deadZone: CGFloat
  let armDistance: CGFloat
}

enum InkSignPdfPageNavigationPolicy {
  static func captureGesture(
    at location: CGPoint,
    viewport: PageViewportTransform,
    activePageIndex: Int,
    pageCount: Int,
    isRTL: Bool,
    screenScale: CGFloat
  ) -> InkSignPdfEdgeNavigationGesture? {
    let pageBounds = viewport.pageFrame
    let edgeTolerance = 1 / screenScale
    guard location.y >= pageBounds.minY - edgeTolerance,
          location.y <= pageBounds.maxY + edgeTolerance,
          location.x >= pageBounds.minX - edgeTolerance,
          location.x <= pageBounds.maxX + edgeTolerance else { return nil }
    let edges = viewport.edgeCoverage(screenScale: screenScale)
    guard edges.visibleWidth > 0 else { return nil }
    let previousEdgeVisible = isRTL
      ? edges.hasPageBoundaryAtRightViewportEdge
      : edges.hasPageBoundaryAtLeftViewportEdge
    let nextEdgeVisible = isRTL
      ? edges.hasPageBoundaryAtLeftViewportEdge
      : edges.hasPageBoundaryAtRightViewportEdge
    return InkSignPdfEdgeNavigationGesture(
      previousEligible: activePageIndex > 0 && previousEdgeVisible,
      nextEligible: activePageIndex + 1 < pageCount && nextEdgeVisible,
      isRTL: isRTL,
      deadZone: 8,
      armDistance: edges.visibleWidth * 0.30)
  }

  static func pageTurnTargetDelta(
    for direction: InkSignPdfEdgeNavigationPhysicalDirection,
    isRTL: Bool
  ) -> Int {
    switch (direction, isRTL) {
    case (.left, false), (.right, true): return 1
    case (.right, false), (.left, true): return -1
    }
  }
}
