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
    bounds: CGRect,
    activePageIndex: Int,
    pageCount: Int,
    isRTL: Bool,
    density: CGFloat
  ) -> InkSignPdfEdgeNavigationGesture? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let pageBounds = viewport.pageFrame
    let edgeTolerance = 1 / max(density, 1)
    guard location.y >= pageBounds.minY - edgeTolerance,
          location.y <= pageBounds.maxY + edgeTolerance,
          location.x >= pageBounds.minX - edgeTolerance,
          location.x <= pageBounds.maxX + edgeTolerance else { return nil }
    let left = viewport.clampedCanonicalPoint(fromView: CGPoint(x: bounds.minX,
                                                                 y: bounds.midY))
    let right = viewport.clampedCanonicalPoint(fromView: CGPoint(x: bounds.maxX,
                                                                  y: bounds.midY))
    let leftAxis = left.applying(viewport.canonicalToDisplay).x
    let rightAxis = right.applying(viewport.canonicalToDisplay).x
    let pageLength = viewport.displaySize.width
    let visibleLength = abs(rightAxis - leftAxis)
    let pointsPerPoint = visibleLength / bounds.width
    let onePixel = pointsPerPoint / max(density, 1)
    guard pageLength.isFinite, pageLength > 0,
          visibleLength.isFinite, visibleLength > 0,
          onePixel.isFinite, onePixel > 0 else { return nil }
    let leftClamped = min(max(leftAxis, 0), pageLength)
    let rightClamped = min(max(rightAxis, 0), pageLength)
    let increasesToRight = rightAxis >= leftAxis
    let leftBoundary = increasesToRight ? 0.0 : pageLength
    let rightBoundary = increasesToRight ? pageLength : 0.0
    let atLeft = abs(leftClamped - leftBoundary) <= onePixel
    let atRight = abs(rightClamped - rightBoundary) <= onePixel
    let visiblePageWidth = pageBounds.intersection(bounds).width
    let armDistance = visiblePageWidth * 0.30
    guard visiblePageWidth.isFinite, visiblePageWidth > 0,
          armDistance.isFinite, armDistance > 0 else { return nil }
    return InkSignPdfEdgeNavigationGesture(
      previousEligible: activePageIndex > 0 && (isRTL ? atRight : atLeft),
      nextEligible: activePageIndex + 1 < pageCount && (isRTL ? atLeft : atRight),
      isRTL: isRTL,
      deadZone: 8,
      armDistance: armDistance)
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
