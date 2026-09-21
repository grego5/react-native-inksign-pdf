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

struct InkSignPdfTileGeometry: Equatable {
  let canonicalRect: CGRect
  let pixelWidth: Int
  let pixelHeight: Int
  let byteCost: Int
}

struct InkSignPdfTilePlan: Equatable {
  static let pixelLimit = 512
  static let maxPendingTiles = 8
  static let maxCacheBytes = 64 * 1024 * 1024

  let renderZoom: CGFloat
  let canonicalTileExtent: CGFloat
  let pageSize: CGSize
  let columns: Int
  let rows: Int
  let density: CGFloat

  init?(pageSize: CGSize, viewportZoom: CGFloat, density: CGFloat) {
    guard pageSize.width.isFinite, pageSize.height.isFinite,
          pageSize.width > 0, pageSize.height > 0,
          viewportZoom.isFinite, viewportZoom > 0,
          density.isFinite, density > 0 else { return nil }
    let renderZoom = min(16, max(0.125, ceil(viewportZoom * 8) / 8))
    self.init(pageSize: pageSize, renderZoom: renderZoom, density: density)
  }

  init?(pageSize: CGSize, renderZoom: CGFloat, density: CGFloat) {
    guard pageSize.width.isFinite, pageSize.height.isFinite,
          pageSize.width > 0, pageSize.height > 0,
          renderZoom.isFinite, renderZoom > 0, renderZoom <= 16,
          density.isFinite, density > 0 else { return nil }
    let canonicalTileExtent = CGFloat(Self.pixelLimit) / (renderZoom * density)
    guard renderZoom.isFinite, renderZoom > 0,
          canonicalTileExtent.isFinite, canonicalTileExtent > 0 else { return nil }
    let columnsValue = ceil(pageSize.width / canonicalTileExtent)
    let rowsValue = ceil(pageSize.height / canonicalTileExtent)
    guard columnsValue.isFinite, rowsValue.isFinite,
          columnsValue >= 1, rowsValue >= 1,
          columnsValue <= CGFloat(Int.max), rowsValue <= CGFloat(Int.max) else {
      return nil
    }
    self.renderZoom = renderZoom
    self.canonicalTileExtent = canonicalTileExtent
    self.pageSize = pageSize
    self.columns = Int(columnsValue)
    self.rows = Int(rowsValue)
    self.density = density
  }

  func tile(column: Int, row: Int) -> InkSignPdfTileGeometry? {
    guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
    let origin = CGPoint(x: CGFloat(column) * canonicalTileExtent,
                         y: CGFloat(row) * canonicalTileExtent)
    let width = min(canonicalTileExtent, pageSize.width - origin.x)
    let height = min(canonicalTileExtent, pageSize.height - origin.y)
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    let rawPixelWidth = ceil(width * renderZoom * density)
    let rawPixelHeight = ceil(height * renderZoom * density)
    guard rawPixelWidth.isFinite, rawPixelHeight.isFinite,
          rawPixelWidth >= 1, rawPixelHeight >= 1,
          rawPixelWidth <= CGFloat(Self.pixelLimit) + 1,
          rawPixelHeight <= CGFloat(Self.pixelLimit) + 1 else {
      return nil
    }
    let pixelWidth = min(Self.pixelLimit, max(1, Int(rawPixelWidth)))
    let pixelHeight = min(Self.pixelLimit, max(1, Int(rawPixelHeight)))
    let stride = pixelWidth.multipliedReportingOverflow(by: 4)
    guard !stride.overflow else { return nil }
    let byteCost = stride.partialValue.multipliedReportingOverflow(by: pixelHeight)
    guard !byteCost.overflow else { return nil }
    return InkSignPdfTileGeometry(
      canonicalRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      byteCost: byteCost.partialValue)
  }
}

private struct InkSignPdfTileCacheEntry {
  let image: UIImage
  let byteCost: Int
  var lastUsed: UInt64
}

/// Owns the iOS page viewport and the PDFium-backed base image. PDFPage is
/// retained only as document metadata for the existing history/export layer.
final class InkPdfView: UIView {
  weak var owner: InkSignView?

  private let pageLayer = UIView()
  private let renderQueue = DispatchQueue(label: "ReactNativeInkSignPdf.ios.tiles",
                                           qos: .userInitiated)
  private var tileViews: [InkSignPdfTileKey: UIImageView] = [:]
  private var tileImages: [InkSignPdfTileKey: InkSignPdfTileCacheEntry] = [:]
  private var failedTiles = Set<InkSignPdfTileKey>()
  private var pendingTiles: [InkSignPdfTileKey: UInt64] = [:]
  private var queuedTileRequests = 0
  private var nextTileRequestID: UInt64 = 0
  private var cacheClock: UInt64 = 0
  private var renderGeneration: UInt64 = 0
  private var pageSession: InkSignPdfPdfiumSession?
  private var pageGeometry = PageGeometry.empty
  private var pageIndex = -1
  private var pageGeneration: UInt64?
  private var pinchStartZoom: CGFloat = 1
  private var pinchStartPoint = CGPoint.zero
  private(set) var viewportTransform: PageViewportTransform?

  var currentPage: PDFPage?
  var minScaleFactor: CGFloat = 0.1
  var maxScaleFactor: CGFloat = 16
  var autoScales = false
  var scaleFactor: CGFloat { viewportTransform?.zoom ?? 1 }

  var scaleFactorForSizeToFit: CGFloat {
    let displaySize = PageViewportTransform.displaySize(for: pageGeometry)
    guard bounds.width > 0, bounds.height > 0,
          displaySize.width > 0, displaySize.height > 0 else { return 0 }
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

  deinit {
    clearTiles()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let current = viewportTransform,
          pageGeneration == current.generation,
          owner?.generation == nil || owner?.generation == current.generation,
          let rebased = current.rebased(to: bounds) else {
      renderGeneration &+= 1
      clearTiles()
      viewportTransform = nil
      pageLayer.frame = .zero
      return
    }
    if current.viewBounds != bounds {
      renderGeneration &+= 1
      clearTiles()
    }
    viewportTransform = rebased
    pageLayer.frame = rebased.pageFrame
    renderTiles(generation: rebased.generation)
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
    session: InkSignPdfPdfiumSession,
    generation: UInt64
  ) {
    renderGeneration &+= 1
    currentPage = page
    pageIndex = index
    pageGeometry = geometry
    pageSession = session
    pageGeneration = generation
    viewportTransform = nil
    clearTiles()
    pageLayer.frame = .zero
  }

  func removePage() {
    renderGeneration &+= 1
    currentPage = nil
    pageSession = nil
    pageIndex = -1
    pageGeometry = .empty
    pageGeneration = nil
    viewportTransform = nil
    clearTiles()
    pageLayer.frame = .zero
  }

  @discardableResult
  func applyViewport(zoom: CGFloat, focus: CGPoint, generation: UInt64) -> Bool {
    guard currentPage != nil, pageGeneration == generation else {
      renderGeneration &+= 1
      clearTiles()
      viewportTransform = nil
      pageLayer.frame = .zero
      return false
    }
    let clampedZoom = min(max(zoom, minScaleFactor), maxScaleFactor)
    guard let transform = PageViewportTransform(
      geometry: pageGeometry,
      bounds: bounds,
      zoom: clampedZoom,
      focus: focus,
      generation: generation) else {
      renderGeneration &+= 1
      clearTiles()
      viewportTransform = nil
      pageLayer.frame = .zero
      return false
    }
    viewportTransform = transform
    pageLayer.frame = transform.pageFrame
    failedTiles.removeAll()
    renderTiles(generation: generation)
    return !pageLayer.frame.isNull && !pageLayer.frame.isEmpty
  }

  func convert(_ point: CGPoint, to page: PDFPage) -> CGPoint {
    guard page === currentPage, let transform = viewportTransform else { return .zero }
    return transform.pdfPoint(fromView: point)
  }

  func convert(_ point: CGPoint, from page: PDFPage) -> CGPoint {
    guard page === currentPage, let transform = viewportTransform else { return .zero }
    return transform.viewPoint(fromPDF: point)
  }

  func convert(_ rect: CGRect, from page: PDFPage) -> CGRect {
    guard page === currentPage, let transform = viewportTransform else { return .zero }
    return transform.viewRect(fromPDF: rect)
  }

  private func renderTiles(generation: UInt64) {
    guard let session = pageSession,
          let viewport = viewportTransform,
          pageIndex >= 0,
          bounds.width > 0, bounds.height > 0 else { return }
    let density = max(UIScreen.main.scale, 1)
    let visible = bounds.intersection(pageLayer.frame)
    guard !visible.isNull, !visible.isEmpty else { return }
    let localVisible = CGRect(x: max(0, visible.minX - pageLayer.frame.minX),
                              y: max(0, visible.minY - pageLayer.frame.minY),
                              width: min(pageLayer.bounds.width, visible.width),
                              height: min(pageLayer.bounds.height, visible.height))
    guard let plan = InkSignPdfTilePlan(pageSize: viewport.displaySize,
                                        viewportZoom: viewport.zoom,
                                        density: density) else { return }
    let viewTileExtent = plan.canonicalTileExtent * viewport.zoom
    guard viewTileExtent.isFinite, viewTileExtent > 0 else { return }
    let firstColumn = max(0, Int(floor(localVisible.minX / viewTileExtent)))
    let firstRow = max(0, Int(floor(localVisible.minY / viewTileExtent)))
    let lastColumn = max(firstColumn, Int(ceil(localVisible.maxX / viewTileExtent)) - 1)
    let lastRow = max(firstRow, Int(ceil(localVisible.maxY / viewTileExtent)) - 1)
    let renderToken = renderGeneration
    var desired = Set<InkSignPdfTileKey>()
    for row in firstRow...min(lastRow, plan.rows - 1) {
      for column in firstColumn...min(lastColumn, plan.columns - 1) {
        let key = InkSignPdfTileKey(generation: generation, pageIndex: pageIndex,
                                    zoomBucket: Int((plan.renderZoom * 8).rounded()),
                                    column: column, row: row)
        desired.insert(key)
        guard let tile = plan.tile(column: column, row: row),
              let frame = frame(for: tile.canonicalRect, viewport: viewport) else {
          continue
        }
        if let entry = tileImages[key] {
          touchCacheEntry(for: key)
          install(image: entry.image, key: key, frame: frame)
          continue
        }
        if failedTiles.contains(key) { continue }
        guard queuedTileRequests < InkSignPdfTilePlan.maxPendingTiles,
              pendingTiles[key] == nil else { continue }
        nextTileRequestID &+= 1
        let requestID = nextTileRequestID
        pendingTiles[key] = requestID
        queuedTileRequests += 1
        let transform = viewport.pdfToDeviceTransform(
          canonicalTileOrigin: tile.canonicalRect.origin,
          renderZoom: plan.renderZoom,
          density: density)
        let pixelWidth = tile.pixelWidth
        let pixelHeight = tile.pixelHeight
        let byteCost = tile.byteCost
        renderQueue.async { [weak self, weak session] in
          var requestWasCurrent = false
          var renderedImage = false
          defer {
            DispatchQueue.main.async { [weak self] in
              guard let self else { return }
              self.queuedTileRequests = max(0, self.queuedTileRequests - 1)
              if self.pendingTiles[key] == requestID {
                self.pendingTiles.removeValue(forKey: key)
              }
              if requestWasCurrent && !renderedImage {
                self.failedTiles.insert(key)
              }
              if let generation = self.pageGeneration,
                 self.viewportTransform?.generation == generation {
                self.renderTiles(generation: generation)
              }
            }
          }
          guard let self, let session else { return }
          let isCurrent = DispatchQueue.main.sync {
            self.isCurrentTileRequest(key, renderToken: renderToken)
          }
          guard isCurrent else { return }
          requestWasCurrent = true
          let strideResult = pixelWidth.multipliedReportingOverflow(by: 4)
          guard !strideResult.overflow else { return }
          let byteResult = strideResult.partialValue.multipliedReportingOverflow(by: pixelHeight)
          guard !byteResult.overflow, byteResult.partialValue == byteCost else { return }
          let pixels = NSMutableData(length: byteResult.partialValue)
          guard let pixels else { return }
          do {
            try session.renderPage(
              UInt(key.pageIndex),
              width: Int32(pixelWidth),
              height: Int32(pixelHeight),
              stride: Int32(strideResult.partialValue),
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
                                      bytesPerRow: strideResult.partialValue,
                                      space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little
                                        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else { return }
            let uiImage = UIImage(cgImage: image, scale: density, orientation: .up)
            renderedImage = true
            DispatchQueue.main.async {
              guard self.isCurrentTileRequest(key, renderToken: renderToken) else { return }
              guard let viewport = self.viewportTransform,
                    let plan = InkSignPdfTilePlan(pageSize: viewport.displaySize,
                                                  viewportZoom: viewport.zoom,
                                                  density: density),
                    let currentTile = plan.tile(column: key.column, row: key.row),
                    let currentFrame = self.frame(for: currentTile.canonicalRect,
                                                  viewport: viewport) else { return }
              self.cacheClock &+= 1
              self.tileImages[key] = InkSignPdfTileCacheEntry(image: uiImage,
                                                               byteCost: byteCost,
                                                               lastUsed: self.cacheClock)
              self.install(image: uiImage, key: key,
                           frame: currentFrame)
              self.boundTileCache(protected: self.protectedVisibleTileKeys().union([key]))
            }
          } catch {
            return
          }
        }
      }
    }
    let visibleCachedKeys = tileImages.keys.filter { key in
      guard key.generation == generation, key.pageIndex == pageIndex,
            let tile = tileGeometry(for: key, plan: plan),
            let frame = frame(for: tile.canonicalRect, viewport: viewport) else { return false }
      return frame.intersects(localVisible)
    }
    for key in visibleCachedKeys {
      guard let entry = tileImages[key],
            let tile = tileGeometry(for: key, plan: plan),
            let frame = frame(for: tile.canonicalRect, viewport: viewport) else { continue }
      touchCacheEntry(for: key)
      install(image: entry.image, key: key, frame: frame)
    }
    let retained = Set(visibleCachedKeys).union(desired)
    tileViews.keys.filter { !retained.contains($0) }.forEach { key in
      tileViews[key]?.removeFromSuperview()
      tileViews.removeValue(forKey: key)
    }
    boundTileCache(protected: retained)
  }

  private func isCurrentTileRequest(_ key: InkSignPdfTileKey,
                                    renderToken: UInt64) -> Bool {
    guard let viewport = viewportTransform else { return false }
    let renderZoom = min(16, max(0.125, ceil(viewport.zoom * 8) / 8))
    return renderGeneration == renderToken &&
      owner?.generation == key.generation &&
      pageIndex == key.pageIndex &&
      viewport.generation == key.generation &&
      viewport.zoom.isFinite &&
      Int((renderZoom * 8).rounded()) == key.zoomBucket
  }

  private func touchCacheEntry(for key: InkSignPdfTileKey) {
    guard var entry = tileImages[key] else { return }
    cacheClock &+= 1
    entry.lastUsed = cacheClock
    tileImages[key] = entry
  }

  private func tileGeometry(for key: InkSignPdfTileKey,
                            plan: InkSignPdfTilePlan) -> InkSignPdfTileGeometry? {
    guard let keyPlan = InkSignPdfTilePlan(
      pageSize: plan.pageSize,
      renderZoom: CGFloat(key.zoomBucket) / 8,
      density: plan.density) else { return nil }
    return keyPlan.tile(column: key.column, row: key.row)
  }

  private func frame(for canonicalRect: CGRect,
                     viewport: PageViewportTransform) -> CGRect? {
    let frame = CGRect(x: canonicalRect.minX * viewport.zoom,
                       y: canonicalRect.minY * viewport.zoom,
                       width: canonicalRect.width * viewport.zoom,
                       height: canonicalRect.height * viewport.zoom)
    guard frame.minX.isFinite, frame.minY.isFinite,
          frame.width.isFinite, frame.height.isFinite,
          !frame.isNull, !frame.isEmpty else { return nil }
    return frame
  }

  private func protectedVisibleTileKeys() -> Set<InkSignPdfTileKey> {
    guard let viewport = viewportTransform,
          let plan = InkSignPdfTilePlan(pageSize: viewport.displaySize,
                                        viewportZoom: viewport.zoom,
                                        density: max(UIScreen.main.scale, 1)) else {
      return []
    }
    let visible = bounds.intersection(pageLayer.frame)
    guard !visible.isNull, !visible.isEmpty else { return [] }
    let localVisible = CGRect(x: max(0, visible.minX - pageLayer.frame.minX),
                              y: max(0, visible.minY - pageLayer.frame.minY),
                              width: min(pageLayer.bounds.width, visible.width),
                              height: min(pageLayer.bounds.height, visible.height))
    return Set(tileImages.keys.filter { key in
      guard key.generation == viewport.generation, key.pageIndex == pageIndex,
            let tile = tileGeometry(for: key, plan: plan),
            let frame = frame(for: tile.canonicalRect, viewport: viewport) else { return false }
      return frame.intersects(localVisible)
    })
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

  private func boundTileCache(protected: Set<InkSignPdfTileKey>) {
    var totalBytes = 0
    for entry in tileImages.values {
      let result = totalBytes.addingReportingOverflow(entry.byteCost)
      totalBytes = result.overflow ? Int.max : result.partialValue
    }
    while totalBytes > InkSignPdfTilePlan.maxCacheBytes, !tileImages.isEmpty {
      let candidate = tileImages.keys
        .filter { !protected.contains($0) }
        .min { (tileImages[$0]?.lastUsed ?? 0) < (tileImages[$1]?.lastUsed ?? 0) }
        ?? tileImages.keys.min { (tileImages[$0]?.lastUsed ?? 0) < (tileImages[$1]?.lastUsed ?? 0) }
      guard let key = candidate, let entry = tileImages.removeValue(forKey: key) else { break }
      totalBytes = max(0, totalBytes - entry.byteCost)
      tileViews[key]?.removeFromSuperview()
      tileViews.removeValue(forKey: key)
    }
  }

  private func clearTiles() {
    tileViews.values.forEach { $0.removeFromSuperview() }
    tileViews.removeAll()
    tileImages.removeAll()
    failedTiles.removeAll()
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
    guard let viewport = viewportTransform else { return }
    let focus = viewport.clampedCanonicalPoint(fromView: CGPoint(
      x: center.x - translation.x,
      y: center.y - translation.y))
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
      guard let viewport = viewportTransform else { return }
      let anchor = viewport.canonicalPoint(fromView: pinchStartPoint)
      let focus = viewport.focus(keepingCanonicalPoint: anchor,
                                atViewPoint: pinchStartPoint,
                                zoom: zoom)
      guard applyViewport(zoom: zoom, focus: focus, generation: owner?.generation ?? 0) else {
        return
      }
      owner?.documentViewViewportChanged(self)
    default:
      break
    }
  }

}
