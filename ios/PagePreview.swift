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
    let displaySize = PageViewportTransform.displaySize(for: request.geometry)
    let fitScale = min(size.width / displaySize.width,
                       size.height / displaySize.height)
    guard let viewport = PageViewportTransform(
      geometry: request.geometry,
      bounds: CGRect(origin: .zero, size: size),
      zoom: fitScale,
      focus: CGPoint(x: request.geometry.mediaBox.width / 2,
                     y: request.geometry.mediaBox.height / 2),
      generation: request.key.generation) else { return nil }
    let pointPdfToPreview = viewport.pdfToViewTransform()
    let pdfToPreview = viewport.pdfToViewTransform(pixelScale: density)
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
        context.cgContext.concatenate(viewport.canonicalToView)
        drawing.image(from: CGRect(origin: .zero,
                                   size: request.geometry.mediaBox.size), scale: 1)
          .draw(in: CGRect(origin: .zero, size: request.geometry.mediaBox.size))
        context.cgContext.restoreGState()
        _ = InkSignPdfTextRenderer.drawForPreview(
          request.textAnnotations,
          pageSize: request.geometry.mediaBox.size,
          mediaBox: request.geometry.mediaBox,
          pdfToPreview: pointPdfToPreview,
          in: context.cgContext)
      }
    } catch {
      return nil
    }
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
