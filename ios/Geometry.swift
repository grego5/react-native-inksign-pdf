import CoreGraphics
import PencilKit
import UIKit

struct PenValue {
  var color: UIColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
  var maxWidth: Double = 4.0
}

struct PageGeometry {
  let mediaBox: CGRect
  let rotation: Int

  static let empty = PageGeometry(mediaBox: .zero, rotation: 0)

  var isValid: Bool {
    mediaBox.minX.isFinite && mediaBox.minY.isFinite &&
      mediaBox.width.isFinite && mediaBox.height.isFinite &&
      mediaBox.width > 0 && mediaBox.height > 0 &&
      [0, 90, 180, 270].contains(PageViewportTransform.normalizedRotation(rotation))
  }
}

/// Describes page boundaries visible at the viewport's physical edges.
struct PageViewportEdgeCoverage {
  let hasPageBoundaryAtLeftViewportEdge: Bool
  let hasPageBoundaryAtRightViewportEdge: Bool
  let visibleWidth: CGFloat
}

/// Immutable mapping for one accepted page viewport.
///
/// Canonical points are media-box-relative with a top-left origin. PDF points
/// use the page's native media-box origin and bottom-left orientation. View
/// points are local to the PDF view's bounds.
struct PageViewportTransform {
  let geometry: PageGeometry
  let rotation: Int
  let generation: UInt64
  let viewBounds: CGRect
  let zoom: CGFloat
  let canonicalFocus: CGPoint
  let displaySize: CGSize
  let pageFrame: CGRect
  let canonicalToDisplay: CGAffineTransform
  let canonicalToView: CGAffineTransform
  let viewToCanonical: CGAffineTransform
  let pdfToDisplay: CGAffineTransform
  let pdfToView: CGAffineTransform

  init?(
    geometry: PageGeometry,
    bounds: CGRect,
    zoom: CGFloat,
    focus: CGPoint,
    generation: UInt64
  ) {
    guard geometry.isValid,
          bounds.minX.isFinite, bounds.minY.isFinite,
          bounds.width.isFinite, bounds.height.isFinite,
          bounds.width > 0, bounds.height > 0,
          zoom.isFinite, zoom > 0,
          focus.x.isFinite, focus.y.isFinite else { return nil }

    let rotation = Self.normalizedRotation(geometry.rotation)
    let displaySize = Self.displaySize(for: geometry)
    let canonicalFocus = Self.clampedFocus(focus,
                                           geometry: geometry,
                                           rotation: rotation,
                                           bounds: bounds,
                                           zoom: zoom)
    let canonicalToDisplay = Self.canonicalToDisplayTransform(
      pageSize: geometry.mediaBox.size,
      rotation: rotation)
    let displayFocus = canonicalFocus.applying(canonicalToDisplay)
    let pageOrigin = CGPoint(
      x: bounds.midX - displayFocus.x * zoom,
      y: bounds.midY - displayFocus.y * zoom)
    let canonicalToView = Self.scaledTransform(canonicalToDisplay,
                                                scale: zoom,
                                                translation: pageOrigin)
    guard let viewToCanonical = canonicalToView.invertedIfFinite else { return nil }
    let pdfToCanonical = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                            tx: -geometry.mediaBox.minX,
                                            ty: geometry.mediaBox.maxY)
    let pdfToDisplay = Self.concatenating(canonicalToDisplay, pdfToCanonical)
    let pdfToView = Self.concatenating(canonicalToView, pdfToCanonical)
    let pageFrame = CGRect(origin: pageOrigin,
                           size: CGSize(width: displaySize.width * zoom,
                                        height: displaySize.height * zoom))

    guard Self.isFinite(canonicalToDisplay),
          Self.isFinite(canonicalToView),
          Self.isFinite(viewToCanonical),
          Self.isFinite(pdfToDisplay),
          Self.isFinite(pdfToView),
          pageFrame.minX.isFinite, pageFrame.minY.isFinite,
          pageFrame.width.isFinite, pageFrame.height.isFinite else { return nil }

    self.geometry = geometry
    self.rotation = rotation
    self.generation = generation
    self.viewBounds = bounds
    self.zoom = zoom
    self.canonicalFocus = canonicalFocus
    self.displaySize = displaySize
    self.pageFrame = pageFrame
    self.canonicalToDisplay = canonicalToDisplay
    self.canonicalToView = canonicalToView
    self.viewToCanonical = viewToCanonical
    self.pdfToDisplay = pdfToDisplay
    self.pdfToView = pdfToView
  }

  func rebased(to bounds: CGRect) -> PageViewportTransform? {
    PageViewportTransform(geometry: geometry,
                          bounds: bounds,
                          zoom: zoom,
                          focus: canonicalFocus,
                          generation: generation)
  }

  func viewPoint(fromCanonical point: CGPoint) -> CGPoint {
    point.applying(canonicalToView)
  }

  func canonicalPoint(fromView point: CGPoint) -> CGPoint {
    point.applying(viewToCanonical)
  }

  func clampedCanonicalPoint(fromView point: CGPoint) -> CGPoint {
    clampedCanonicalPoint(canonicalPoint(fromView: point))
  }

  /// Reports page-edge visibility and width in the viewport's coordinate space.
  func edgeCoverage(screenScale: CGFloat) -> PageViewportEdgeCoverage {
    let leftViewportPageX = clampedCanonicalPoint(fromView: CGPoint(x: viewBounds.minX,
                                                                     y: viewBounds.midY))
      .applying(canonicalToDisplay).x
    let rightViewportPageX = clampedCanonicalPoint(fromView: CGPoint(x: viewBounds.maxX,
                                                                      y: viewBounds.midY))
      .applying(canonicalToDisplay).x
    let pageWidth = displaySize.width
    let pageUnitsPerPixel = abs(rightViewportPageX - leftViewportPageX) /
      viewBounds.width / screenScale
    let pageMovesRight = rightViewportPageX >= leftViewportPageX
    let leftPageBoundary = pageMovesRight ? 0.0 : pageWidth
    let rightPageBoundary = pageMovesRight ? pageWidth : 0.0

    return PageViewportEdgeCoverage(
      hasPageBoundaryAtLeftViewportEdge:
        abs(min(max(leftViewportPageX, 0), pageWidth) - leftPageBoundary) <= pageUnitsPerPixel,
      hasPageBoundaryAtRightViewportEdge:
        abs(min(max(rightViewportPageX, 0), pageWidth) - rightPageBoundary) <= pageUnitsPerPixel,
      visibleWidth: pageFrame.intersection(viewBounds).width)
  }

  func pdfPoint(fromCanonical point: CGPoint) -> CGPoint {
    let mediaBox = geometry.mediaBox
    return CGPoint(x: point.x + mediaBox.minX,
                   y: mediaBox.maxY - point.y)
  }

  func canonicalPoint(fromPDF point: CGPoint) -> CGPoint {
    let mediaBox = geometry.mediaBox
    return CGPoint(x: point.x - mediaBox.minX,
                   y: mediaBox.maxY - point.y)
  }

  func viewPoint(fromPDF point: CGPoint) -> CGPoint {
    point.applying(pdfToView)
  }

  func pdfPoint(fromView point: CGPoint) -> CGPoint {
    pdfPoint(fromCanonical: clampedCanonicalPoint(fromView: point))
  }

  func focus(
    keepingCanonicalPoint anchor: CGPoint,
    atViewPoint viewPoint: CGPoint,
    zoom: CGFloat
  ) -> CGPoint {
    guard zoom.isFinite, zoom > 0,
          let displayToCanonical = canonicalToDisplay.invertedIfFinite else {
      return canonicalFocus
    }
    let displayAnchor = anchor.applying(canonicalToDisplay)
    let targetDisplayFocus = CGPoint(
      x: displayAnchor.x - (viewPoint.x - viewBounds.midX) / zoom,
      y: displayAnchor.y - (viewPoint.y - viewBounds.midY) / zoom)
    let target = targetDisplayFocus.applying(displayToCanonical)
    return Self.clampedFocus(target,
                             geometry: geometry,
                             rotation: rotation,
                             bounds: viewBounds,
                             zoom: zoom)
  }

  func viewRect(fromCanonical rect: CGRect) -> CGRect {
    Self.boundingRect(of: [
      viewPoint(fromCanonical: CGPoint(x: rect.minX, y: rect.minY)),
      viewPoint(fromCanonical: CGPoint(x: rect.maxX, y: rect.minY)),
      viewPoint(fromCanonical: CGPoint(x: rect.minX, y: rect.maxY)),
      viewPoint(fromCanonical: CGPoint(x: rect.maxX, y: rect.maxY)),
    ])
  }

  func viewRect(fromPDF rect: CGRect) -> CGRect {
    Self.boundingRect(of: [
      viewPoint(fromPDF: CGPoint(x: rect.minX, y: rect.minY)),
      viewPoint(fromPDF: CGPoint(x: rect.maxX, y: rect.minY)),
      viewPoint(fromPDF: CGPoint(x: rect.minX, y: rect.maxY)),
      viewPoint(fromPDF: CGPoint(x: rect.maxX, y: rect.maxY)),
    ])
  }

  func pdfToDeviceTransform(tileOrigin: CGPoint, density: CGFloat) -> CGAffineTransform {
    let scale = zoom * density
    return CGAffineTransform(
      a: pdfToDisplay.a * scale,
      b: pdfToDisplay.b * scale,
      c: pdfToDisplay.c * scale,
      d: pdfToDisplay.d * scale,
      tx: pdfToDisplay.tx * scale - tileOrigin.x * density,
      ty: pdfToDisplay.ty * scale - tileOrigin.y * density
    )
  }

  func pdfToDeviceTransform(canonicalTileOrigin: CGPoint,
                            renderZoom: CGFloat,
                            density: CGFloat) -> CGAffineTransform {
    let scale = renderZoom * density
    return CGAffineTransform(
      a: pdfToDisplay.a * scale,
      b: pdfToDisplay.b * scale,
      c: pdfToDisplay.c * scale,
      d: pdfToDisplay.d * scale,
      tx: pdfToDisplay.tx * scale - canonicalTileOrigin.x * scale,
      ty: pdfToDisplay.ty * scale - canonicalTileOrigin.y * scale
    )
  }

  func pdfToViewTransform(pixelScale: CGFloat = 1) -> CGAffineTransform {
    CGAffineTransform(a: pdfToView.a * pixelScale,
                      b: pdfToView.b * pixelScale,
                      c: pdfToView.c * pixelScale,
                      d: pdfToView.d * pixelScale,
                      tx: pdfToView.tx * pixelScale,
                      ty: pdfToView.ty * pixelScale)
  }

  static func normalizedRotation(_ rotation: Int) -> Int {
    ((rotation % 360) + 360) % 360
  }

  static func displaySize(for geometry: PageGeometry) -> CGSize {
    let rotation = normalizedRotation(geometry.rotation)
    return rotation == 90 || rotation == 270
      ? CGSize(width: geometry.mediaBox.height, height: geometry.mediaBox.width)
      : geometry.mediaBox.size
  }

  private static func canonicalToDisplayTransform(
    pageSize: CGSize,
    rotation: Int
  ) -> CGAffineTransform {
    switch rotation {
    case 90:
      return CGAffineTransform(a: 0, b: -1, c: 1, d: 0,
                               tx: 0, ty: pageSize.width)
    case 180:
      return CGAffineTransform(a: -1, b: 0, c: 0, d: -1,
                               tx: pageSize.width, ty: pageSize.height)
    case 270:
      return CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                               tx: pageSize.height, ty: 0)
    default:
      return .identity
    }
  }

  private static func clampedFocus(
    _ point: CGPoint,
    geometry: PageGeometry,
    rotation: Int,
    bounds: CGRect,
    zoom: CGFloat
  ) -> CGPoint {
    let pageSize = geometry.mediaBox.size
    let candidate = CGPoint(
      x: min(max(point.x, 0), pageSize.width),
      y: min(max(point.y, 0), pageSize.height))
    let visibleWidth = bounds.width / zoom
    let visibleHeight = bounds.height / zoom
    let visibleCanonicalWidth = rotation == 90 || rotation == 270
      ? visibleHeight : visibleWidth
    let visibleCanonicalHeight = rotation == 90 || rotation == 270
      ? visibleWidth : visibleHeight
    return CGPoint(
      x: clampedCoordinate(candidate.x,
                           pageLength: pageSize.width,
                           visibleLength: visibleCanonicalWidth),
      y: clampedCoordinate(candidate.y,
                           pageLength: pageSize.height,
                           visibleLength: visibleCanonicalHeight))
  }

  private static func clampedCoordinate(
    _ value: CGFloat,
    pageLength: CGFloat,
    visibleLength: CGFloat
  ) -> CGFloat {
    guard visibleLength.isFinite, visibleLength > 0 else {
      return min(max(value, 0), pageLength)
    }
    if visibleLength >= pageLength { return pageLength / 2 }
    return min(max(value, visibleLength / 2), pageLength - visibleLength / 2)
  }

  private func clampedCanonicalPoint(_ point: CGPoint) -> CGPoint {
    let size = geometry.mediaBox.size
    return CGPoint(x: min(max(point.x, 0), size.width),
                   y: min(max(point.y, 0), size.height))
  }

  private static func scaledTransform(
    _ transform: CGAffineTransform,
    scale: CGFloat,
    translation: CGPoint
  ) -> CGAffineTransform {
    CGAffineTransform(a: transform.a * scale,
                      b: transform.b * scale,
                      c: transform.c * scale,
                      d: transform.d * scale,
                      tx: transform.tx * scale + translation.x,
                      ty: transform.ty * scale + translation.y)
  }

  private static func concatenating(
    _ outer: CGAffineTransform,
    _ inner: CGAffineTransform
  ) -> CGAffineTransform {
    CGAffineTransform(
      a: outer.a * inner.a + outer.c * inner.b,
      b: outer.b * inner.a + outer.d * inner.b,
      c: outer.a * inner.c + outer.c * inner.d,
      d: outer.b * inner.c + outer.d * inner.d,
      tx: outer.a * inner.tx + outer.c * inner.ty + outer.tx,
      ty: outer.b * inner.tx + outer.d * inner.ty + outer.ty
    )
  }

  private static func boundingRect(of points: [CGPoint]) -> CGRect {
    CGRect(x: points.map(\.x).min() ?? 0,
           y: points.map(\.y).min() ?? 0,
           width: (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
           height: (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0))
  }

  private static func isFinite(_ transform: CGAffineTransform) -> Bool {
    transform.a.isFinite && transform.b.isFinite && transform.c.isFinite &&
      transform.d.isFinite && transform.tx.isFinite && transform.ty.isFinite
  }
}
