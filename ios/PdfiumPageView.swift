import CoreGraphics
import PDFKit
import UIKit

private let inkSignPdfiumRenderFlags: UInt32 = 0x03 // FPDF_ANNOT | FPDF_LCD_TEXT

private struct InkSignPdfTileKey: Hashable {
  let generation: UInt64
  let pageIndex: Int
  let zoomBucket: Int
  let column: Int
  let row: Int
}

/// Owns the iOS page viewport and the PDFium-backed base image. PDFPage is
/// retained only as document metadata for the existing history/export layer.
final class InkPdfView: UIView {
  weak var owner: InkSignView?

  private let pageLayer = UIView()
  private let renderQueue = DispatchQueue(label: "ReactNativeInkSignPdf.ios.tiles",
                                           qos: .userInitiated)
  private var tileViews: [InkSignPdfTileKey: UIImageView] = [:]
  private var tileImages: [InkSignPdfTileKey: UIImage] = [:]
  private var pendingTiles = Set<InkSignPdfTileKey>()
  private var renderGeneration: UInt64 = 0
  private var pageSize = CGSize.zero
  private var displaySize = CGSize.zero
  private var pageFocus = CGPoint.zero
  private var pageSession: InkSignPdfPdfiumSession?
  private var pageGeometry = PageGeometry.empty
  private var pageIndex = -1
  private var hasAppliedViewport = false
  private var pinchStartZoom: CGFloat = 1
  private var pinchStartPoint = CGPoint.zero

  var currentPage: PDFPage?
  var minScaleFactor: CGFloat = 0.1
  var maxScaleFactor: CGFloat = 16
  var autoScales = false
  private(set) var scaleFactor: CGFloat = 1

  var scaleFactorForSizeToFit: CGFloat {
    guard bounds.width > 0, bounds.height > 0, displaySize.width > 0,
          displaySize.height > 0 else { return 0 }
    return min(bounds.width / displaySize.width, bounds.height / displaySize.height)
  }

  private lazy var panGesture: UIPanGestureRecognizer = {
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    gesture.maximumNumberOfTouches = 2
    return gesture
  }()

  private lazy var pinchGesture: UIPinchGestureRecognizer = {
    UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = .white
    isOpaque = true
    pageLayer.isUserInteractionEnabled = false
    addSubview(pageLayer)
    addGestureRecognizer(panGesture)
    addGestureRecognizer(pinchGesture)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    clipsToBounds = true
    backgroundColor = .white
    isOpaque = true
    pageLayer.isUserInteractionEnabled = false
    addSubview(pageLayer)
    addGestureRecognizer(panGesture)
    addGestureRecognizer(pinchGesture)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updatePageLayout()
    guard hasAppliedViewport else { return }
    renderTiles(generation: owner?.generation ?? 0)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if event?.allTouches?.contains(where: { $0.phase == .began }) == true {
      owner?.documentViewNavigationTouchBegan(self)
    }
    return super.hitTest(point, with: event)
  }

  func installPage(
    index: Int,
    page: PDFPage,
    geometry: PageGeometry,
    session: InkSignPdfPdfiumSession
  ) {
    renderGeneration &+= 1
    currentPage = page
    pageIndex = index
    pageGeometry = geometry
    pageSession = session
    pageSize = geometry.mediaBox.size
    displaySize = rotatedSize(for: geometry)
    pageFocus = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
    scaleFactor = 1
    hasAppliedViewport = false
    clearTiles()
    pageLayer.frame = .zero
  }

  func removePage() {
    renderGeneration &+= 1
    currentPage = nil
    pageSession = nil
    pageIndex = -1
    pageGeometry = .empty
    pageSize = .zero
    displaySize = .zero
    hasAppliedViewport = false
    clearTiles()
    pageLayer.frame = .zero
  }

  @discardableResult
  func applyViewport(zoom: CGFloat, focus: CGPoint, generation: UInt64) -> Bool {
    guard currentPage != nil,
          pageSize.width > 0, pageSize.height > 0,
          displaySize.width > 0, displaySize.height > 0,
          bounds.width > 0, bounds.height > 0,
          zoom.isFinite, focus.x.isFinite, focus.y.isFinite else {
      return false
    }
    let clampedZoom = min(max(zoom, minScaleFactor), maxScaleFactor)
    let clampedFocus = clampedViewportFocus(focus, at: clampedZoom)
    scaleFactor = clampedZoom
    pageFocus = clampedFocus
    hasAppliedViewport = true
    updatePageLayout()
    renderTiles(generation: generation)
    return !pageLayer.frame.isNull && !pageLayer.frame.isEmpty
  }

  func convert(_ point: CGPoint, to page: PDFPage) -> CGPoint {
    guard page === currentPage else { return .zero }
    let canonical = canonicalPointFromView(point)
    let mediaBox = pageGeometry.mediaBox
    return CGPoint(x: canonical.x + mediaBox.minX,
                   y: mediaBox.maxY - canonical.y)
  }

  func convert(_ point: CGPoint, from page: PDFPage) -> CGPoint {
    guard page === currentPage else { return .zero }
    let mediaBox = pageGeometry.mediaBox
    let canonical = canonicalPoint(fromPDF: CGPoint(
      x: point.x - mediaBox.minX,
      y: mediaBox.maxY - point.y))
    return displayPoint(fromCanonical: canonical)
  }

  func convert(_ rect: CGRect, from page: PDFPage) -> CGRect {
    let corners = [
      convert(CGPoint(x: rect.minX, y: rect.minY), from: page),
      convert(CGPoint(x: rect.maxX, y: rect.minY), from: page),
      convert(CGPoint(x: rect.minX, y: rect.maxY), from: page),
      convert(CGPoint(x: rect.maxX, y: rect.maxY), from: page),
    ]
    return CGRect(x: corners.map(\.x).min() ?? 0,
                  y: corners.map(\.y).min() ?? 0,
                  width: (corners.map(\.x).max() ?? 0) - (corners.map(\.x).min() ?? 0),
                  height: (corners.map(\.y).max() ?? 0) - (corners.map(\.y).min() ?? 0))
  }

  private func rotatedSize(for geometry: PageGeometry) -> CGSize {
    let rotation = ((geometry.rotation % 360) + 360) % 360
    return rotation == 90 || rotation == 270
      ? CGSize(width: geometry.mediaBox.height, height: geometry.mediaBox.width)
      : geometry.mediaBox.size
  }

  private func updatePageLayout() {
    guard pageSize.width > 0, pageSize.height > 0,
          displaySize.width > 0, displaySize.height > 0 else {
      pageLayer.frame = .zero
      return
    }
    let scaledSize = CGSize(width: displaySize.width * scaleFactor,
                            height: displaySize.height * scaleFactor)
    let focus = displayPoint(fromCanonical: pageFocus)
    pageLayer.frame = CGRect(
      x: bounds.midX - focus.x * scaleFactor,
      y: bounds.midY - focus.y * scaleFactor,
      width: scaledSize.width,
      height: scaledSize.height)
  }

  private func clampedViewportFocus(_ point: CGPoint, at zoom: CGFloat) -> CGPoint {
    let candidate = canonicalPoint(fromPDF: point)
    guard zoom.isFinite, zoom > 0, bounds.width > 0, bounds.height > 0 else {
      return candidate
    }
    let visibleWidth = bounds.width / zoom
    let visibleHeight = bounds.height / zoom
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    let visibleCanonicalWidth = rotation == 90 || rotation == 270 ? visibleHeight : visibleWidth
    let visibleCanonicalHeight = rotation == 90 || rotation == 270 ? visibleWidth : visibleHeight
    return CGPoint(
      x: clampedViewportCoordinate(candidate.x,
                                   pageLength: pageSize.width,
                                   visibleLength: visibleCanonicalWidth),
      y: clampedViewportCoordinate(candidate.y,
                                   pageLength: pageSize.height,
                                   visibleLength: visibleCanonicalHeight))
  }

  private func clampedViewportCoordinate(
    _ value: CGFloat,
    pageLength: CGFloat,
    visibleLength: CGFloat
  ) -> CGFloat {
    let candidate = value.isFinite ? value : pageLength / 2
    guard visibleLength.isFinite, visibleLength > 0 else {
      return min(max(candidate, 0), pageLength)
    }
    if visibleLength >= pageLength { return pageLength / 2 }
    return min(max(candidate, visibleLength / 2), pageLength - visibleLength / 2)
  }

  private func canonicalPoint(fromPDF point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(point.x, 0), pageSize.width),
            y: min(max(point.y, 0), pageSize.height))
  }

  private func canonicalPointFromView(_ point: CGPoint) -> CGPoint {
    guard scaleFactor > 0 else { return .zero }
    let display = CGPoint(x: (point.x - pageLayer.frame.minX) / scaleFactor,
                          y: (point.y - pageLayer.frame.minY) / scaleFactor)
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    let result: CGPoint
    switch rotation {
    case 90:
      result = CGPoint(x: pageSize.width - display.y, y: display.x)
    case 180:
      result = CGPoint(x: pageSize.width - display.x, y: pageSize.height - display.y)
    case 270:
      result = CGPoint(x: display.y, y: pageSize.height - display.x)
    default:
      result = display
    }
    return canonicalPoint(fromPDF: result)
  }

  private func displayPoint(fromCanonical point: CGPoint) -> CGPoint {
    let x = min(max(point.x, 0), pageSize.width)
    let y = min(max(point.y, 0), pageSize.height)
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    switch rotation {
    case 90: return CGPoint(x: y, y: pageSize.width - x)
    case 180: return CGPoint(x: pageSize.width - x, y: pageSize.height - y)
    case 270: return CGPoint(x: pageSize.height - y, y: x)
    default: return CGPoint(x: x, y: y)
    }
  }

  private func pdfiumTransform(tileOrigin: CGPoint, density: CGFloat) -> CGAffineTransform {
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    let scale = scaleFactor * density
    let w = pageSize.width
    let h = pageSize.height
    let base: CGAffineTransform
    switch rotation {
    case 90: base = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
    case 180: base = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
    case 270: base = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    default: base = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    }
    return CGAffineTransform(a: base.a * scale,
                             b: base.b * scale,
                             c: base.c * scale,
                             d: base.d * scale,
                             tx: base.tx * scale - tileOrigin.x * density,
                             ty: base.ty * scale - tileOrigin.y * density)
  }

  private func renderTiles(generation: UInt64) {
    guard let session = pageSession, pageIndex >= 0,
          bounds.width > 0, bounds.height > 0 else { return }
    let tilePoints: CGFloat = 512
    let density = max(UIScreen.main.scale, 1)
    let visible = bounds.intersection(pageLayer.frame)
    guard !visible.isNull, !visible.isEmpty else { return }
    let localVisible = CGRect(x: max(0, visible.minX - pageLayer.frame.minX),
                              y: max(0, visible.minY - pageLayer.frame.minY),
                              width: min(pageLayer.bounds.width, visible.width),
                              height: min(pageLayer.bounds.height, visible.height))
    let firstColumn = max(0, Int(floor(localVisible.minX / (tilePoints * scaleFactor))))
    let firstRow = max(0, Int(floor(localVisible.minY / (tilePoints * scaleFactor))))
    let lastColumn = max(firstColumn, Int(ceil(localVisible.maxX / (tilePoints * scaleFactor))) - 1)
    let lastRow = max(firstRow, Int(ceil(localVisible.maxY / (tilePoints * scaleFactor))) - 1)
    let columns = Int(ceil(displaySize.width / tilePoints))
    let rows = Int(ceil(displaySize.height / tilePoints))
    let zoomBucket = Int((scaleFactor * 100).rounded())
    let renderToken = renderGeneration
    var desired = Set<InkSignPdfTileKey>()
    for row in firstRow...min(lastRow, rows - 1) {
      for column in firstColumn...min(lastColumn, columns - 1) {
        let key = InkSignPdfTileKey(generation: generation, pageIndex: pageIndex,
                                    zoomBucket: zoomBucket, column: column, row: row)
        desired.insert(key)
        let tileOrigin = CGPoint(x: CGFloat(column) * tilePoints * scaleFactor,
                                 y: CGFloat(row) * tilePoints * scaleFactor)
        let tileWidth = min(tilePoints * scaleFactor, pageLayer.bounds.width - tileOrigin.x)
        let tileHeight = min(tilePoints * scaleFactor, pageLayer.bounds.height - tileOrigin.y)
        guard tileWidth > 0, tileHeight > 0 else { continue }
        if let image = tileImages[key] {
          install(image: image, key: key, frame: CGRect(origin: tileOrigin,
                                                        size: CGSize(width: tileWidth,
                                                                     height: tileHeight)))
          continue
        }
        guard !pendingTiles.contains(key) else { continue }
        pendingTiles.insert(key)
        let pixelWidth = max(1, Int(ceil(tileWidth * density)))
        let pixelHeight = max(1, Int(ceil(tileHeight * density)))
        let transform = pdfiumTransform(tileOrigin: tileOrigin, density: density)
        renderQueue.async { [weak self, weak session] in
          defer {
            DispatchQueue.main.async { [weak self] in
              self?.pendingTiles.remove(key)
            }
          }
          guard let self, let session else { return }
          let isCurrent = DispatchQueue.main.sync {
            self.isCurrentTileRequest(key, renderToken: renderToken)
          }
          guard isCurrent else { return }
          let pixels = NSMutableData(length: pixelWidth * pixelHeight * 4)
          guard let pixels else { return }
          do {
            try session.renderPage(
              UInt(key.pageIndex),
              width: Int32(pixelWidth),
              height: Int32(pixelHeight),
              stride: Int32(pixelWidth * 4),
              pageToDevice: transform,
              clip: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
              background: UInt32.max,
              flags: inkSignPdfiumRenderFlags,
              pixels: pixels)
            let data = pixels as Data
            guard let provider = CGDataProvider(data: data as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: pixelWidth * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little
                                        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else { return }
            let uiImage = UIImage(cgImage: image, scale: density, orientation: .up)
            DispatchQueue.main.async {
              guard self.isCurrentTileRequest(key, renderToken: renderToken) else { return }
              self.tileImages[key] = uiImage
              self.install(image: uiImage, key: key,
                           frame: CGRect(origin: tileOrigin,
                                         size: CGSize(width: tileWidth, height: tileHeight)))
              self.boundTileCache()
            }
          } catch {
            return
          }
        }
      }
    }
    tileViews.keys.filter { !desired.contains($0) }.forEach { key in
      tileViews[key]?.removeFromSuperview()
      tileViews.removeValue(forKey: key)
    }
  }

  private func isCurrentTileRequest(_ key: InkSignPdfTileKey,
                                    renderToken: UInt64) -> Bool {
    renderGeneration == renderToken &&
      owner?.generation == key.generation &&
      pageIndex == key.pageIndex &&
      scaleFactor.isFinite &&
      Int((scaleFactor * 100).rounded()) == key.zoomBucket
  }

  private func install(image: UIImage, key: InkSignPdfTileKey, frame: CGRect) {
    let imageView = tileViews[key] ?? {
      let view = UIImageView()
      view.contentMode = .scaleToFill
      view.isUserInteractionEnabled = false
      pageLayer.addSubview(view)
      tileViews[key] = view
      return view
    }()
    imageView.image = image
    imageView.frame = frame
  }

  private func boundTileCache() {
    guard tileImages.count > 64 else { return }
    let stale = tileImages.keys.filter { tileViews[$0] == nil }
    for key in stale.prefix(max(0, tileImages.count - 64)) {
      tileImages.removeValue(forKey: key)
    }
  }

  private func clearTiles() {
    tileViews.values.forEach { $0.removeFromSuperview() }
    tileViews.removeAll()
    tileImages.removeAll()
    pendingTiles.removeAll()
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard owner?.editMode == false else { return }
    if gesture.state == .began { owner?.documentViewNavigationTouchBegan(self) }
    guard gesture.state == .changed else { return }
    let translation = gesture.translation(in: self)
    gesture.setTranslation(.zero, in: self)
    guard bounds.width > 0, bounds.height > 0,
          translation.x.isFinite, translation.y.isFinite else { return }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let focus = canonicalPointFromView(
      CGPoint(x: center.x - translation.x, y: center.y - translation.y))
    guard applyViewport(zoom: scaleFactor,
                        focus: focus,
                        generation: owner?.generation ?? 0) else { return }
    owner?.documentViewViewportChanged(self)
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    guard owner?.editMode == false else { return }
    switch gesture.state {
    case .began:
      owner?.documentViewNavigationTouchBegan(self)
      pinchStartZoom = scaleFactor
      pinchStartPoint = gesture.location(in: self)
    case .changed:
      let zoom = min(max(pinchStartZoom * gesture.scale, minScaleFactor), maxScaleFactor)
      let anchor = canonicalPointFromView(pinchStartPoint)
      let focus = canonicalPoint(anchor: anchor, keepingViewPoint: pinchStartPoint, zoom: zoom)
      guard applyViewport(zoom: zoom, focus: focus, generation: owner?.generation ?? 0) else {
        return
      }
      owner?.documentViewViewportChanged(self)
    default:
      break
    }
  }

  private func canonicalPoint(anchor: CGPoint, keepingViewPoint point: CGPoint,
                              zoom: CGFloat) -> CGPoint {
    let displayAnchor = displayPoint(fromCanonical: anchor)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let targetDisplay = CGPoint(x: (point.x - center.x) / zoom + displayAnchor.x,
                                y: (point.y - center.y) / zoom + displayAnchor.y)
    let rotation = ((pageGeometry.rotation % 360) + 360) % 360
    switch rotation {
    case 90: return canonicalPoint(fromPDF: CGPoint(x: pageSize.width - targetDisplay.y,
                                                    y: targetDisplay.x))
    case 180: return canonicalPoint(fromPDF: CGPoint(x: pageSize.width - targetDisplay.x,
                                                     y: pageSize.height - targetDisplay.y))
    case 270: return canonicalPoint(fromPDF: CGPoint(x: targetDisplay.y,
                                                     y: pageSize.height - targetDisplay.x))
    default: return canonicalPoint(fromPDF: targetDisplay)
    }
  }
}
