import CoreGraphics
import PencilKit
import UIKit

struct InkSignPdfPageTurnPreviewKey: Hashable {
  let generation: UInt64
  let sourcePageIndex: Int
  let targetPageIndex: Int
  let direction: InkSignPdfEdgeNavigationPhysicalDirection
  let targetScale: CGFloat
  let targetFocusX: CGFloat
  let targetFocusY: CGFloat
  let targetOriginX: CGFloat
  let targetOriginY: CGFloat
  let targetWidth: CGFloat
  let targetHeight: CGFloat
  let viewportWidth: CGFloat
  let viewportHeight: CGFloat
  let density: CGFloat
  let targetContentRevision: UInt64
  let isRTL: Bool
}

struct InkSignPdfPageTurnPreviewRequest {
  let key: InkSignPdfPageTurnPreviewKey
  let pdfiumSession: InkSignPdfPdfiumSession
  let geometry: PageGeometry
  let drawingData: Data
  let textAnnotations: [InkSignPdfTextAnnotation]
  let size: CGSize
  let frame: CGRect
}

final class InkSignPdfPageTurnPreviewView: UIView {
  private let imageView = UIImageView()
  private var imageFrame = CGRect.zero
  private(set) var key: InkSignPdfPageTurnPreviewKey?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    clipsToBounds = true
    backgroundColor = .clear
    imageView.contentMode = .scaleToFill
    imageView.isUserInteractionEnabled = false
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = imageFrame
  }

  /// Renders the base page with PDFium on the preview worker, then composites
  /// only committed ink and text presentation on the resulting image.
  static func render(request: InkSignPdfPageTurnPreviewRequest) -> UIImage? {
    let size = request.size
    guard size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0,
          request.geometry.isValid,
          let drawing = try? PKDrawing(data: request.drawingData) else { return nil }

    let density = max(request.key.density, 1)
    let pixelWidth = max(1, Int(ceil(size.width * density)))
    let pixelHeight = max(1, Int(ceil(size.height * density)))
    let pixels = NSMutableData(length: pixelWidth * pixelHeight * 4)
    guard let pixels else { return nil }
    let pointPdfToPreview = pdfiumTransform(for: request.geometry,
                                            outputSize: size,
                                            pixelScale: 1)
    let pdfToPreview = pdfiumTransform(for: request.geometry,
                                       outputSize: size,
                                       pixelScale: density)
    do {
      try request.pdfiumSession.renderPage(
        UInt(request.key.targetPageIndex),
        width: Int32(pixelWidth),
        height: Int32(pixelHeight),
        stride: Int32(pixelWidth * 4),
        pageToDevice: pdfToPreview,
        clip: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
        background: UInt32.max,
        flags: 0x03,
        pixels: pixels)
      guard let provider = CGDataProvider(data: pixels as Data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(width: pixelWidth, height: pixelHeight,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: pixelWidth * 4,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little
                                  .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent) else {
        return nil
      }

      let pageImage = UIImage(cgImage: image, scale: density, orientation: .up)
      let renderer = UIGraphicsImageRenderer(size: size, format: {
        let format = UIGraphicsImageRendererFormat()
        format.scale = density
        format.opaque = true
        return format
      }())
      return renderer.image { context in
        pageImage.draw(in: CGRect(origin: .zero, size: size))
        context.cgContext.saveGState()
        context.cgContext.concatenate(canonicalToPreviewTransform(
          for: request.geometry, outputSize: size))
        drawing.image(from: CGRect(origin: .zero,
                                   size: request.geometry.mediaBox.size), scale: 1)
          .draw(in: CGRect(origin: .zero, size: request.geometry.mediaBox.size))
        context.cgContext.restoreGState()
        _ = InkSignPdfTextRenderer.drawForPreview(
          request.textAnnotations,
          pageSize: request.geometry.mediaBox.size,
          mediaBox: request.geometry.mediaBox,
          pdfToPreview: CGAffineTransform(
            translationX: -request.geometry.mediaBox.minX,
            y: -request.geometry.mediaBox.minY
          ).concatenating(pointPdfToPreview),
          in: context.cgContext)
      }
    } catch {
      return nil
    }
  }

  private static func rotatedSize(for geometry: PageGeometry) -> CGSize {
    let rotation = ((geometry.rotation % 360) + 360) % 360
    return rotation == 90 || rotation == 270
      ? CGSize(width: geometry.mediaBox.height, height: geometry.mediaBox.width)
      : geometry.mediaBox.size
  }

  private static func pdfToDisplayTransform(for geometry: PageGeometry) -> CGAffineTransform {
    let w = geometry.mediaBox.width
    let h = geometry.mediaBox.height
    switch ((geometry.rotation % 360) + 360) % 360 {
    case 90: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
    case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
    case 270: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    default: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    }
  }

  private static func canonicalToDisplayTransform(for geometry: PageGeometry) -> CGAffineTransform {
    let w = geometry.mediaBox.width
    let h = geometry.mediaBox.height
    switch ((geometry.rotation % 360) + 360) % 360 {
    case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
    case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
    default: return .identity
    }
  }

  private static func canonicalToPreviewTransform(
    for geometry: PageGeometry,
    outputSize: CGSize
  ) -> CGAffineTransform {
    let base = canonicalToDisplayTransform(for: geometry)
    let displaySize = rotatedSize(for: geometry)
    let scale = min(outputSize.width / displaySize.width,
                    outputSize.height / displaySize.height)
    let xOffset = (outputSize.width - displaySize.width * scale) / 2
    let yOffset = (outputSize.height - displaySize.height * scale) / 2
    return CGAffineTransform(a: base.a * scale, b: base.b * scale,
                             c: base.c * scale, d: base.d * scale,
                             tx: base.tx * scale + xOffset,
                             ty: base.ty * scale + yOffset)
  }

  private static func pdfiumTransform(
    for geometry: PageGeometry,
    outputSize: CGSize,
    pixelScale: CGFloat
  ) -> CGAffineTransform {
    let base = pdfToDisplayTransform(for: geometry)
    let displaySize = rotatedSize(for: geometry)
    let scale = min(outputSize.width / displaySize.width,
                    outputSize.height / displaySize.height)
    let xOffset = (outputSize.width - displaySize.width * scale) / 2
    let yOffset = (outputSize.height - displaySize.height * scale) / 2
    return CGAffineTransform(a: base.a * scale * pixelScale,
                             b: base.b * scale * pixelScale,
                             c: base.c * scale * pixelScale,
                             d: base.d * scale * pixelScale,
                             tx: base.tx * scale * pixelScale + xOffset * pixelScale,
                             ty: base.ty * scale * pixelScale + yOffset * pixelScale)
  }

  func install(image: UIImage, key: InkSignPdfPageTurnPreviewKey, frame: CGRect) -> Bool {
    guard frame.width.isFinite, frame.height.isFinite,
          frame.width > 0, frame.height > 0 else { return false }
    self.key = key
    imageView.image = image
    imageFrame = frame
    setNeedsLayout()
    isHidden = false
    return true
  }

  func clear() {
    key = nil
    imageView.image = nil
    imageFrame = .zero
    isHidden = true
  }
}
