import CoreGraphics
import PDFKit
import PencilKit
import UIKit

enum InkSignPdfEdgeNavigationPhysicalDirection: Hashable {
  case left
  case right
}

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
  let sourceURL: URL
  let drawingData: Data
  let compatibilityTextRuns: [InkSignPdfCompatibilityTextRun]
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

  /// This function runs on the preview worker. It opens its own PDF document so
  /// no PDFKit page owned by the main-thread viewer crosses the queue boundary.
  static func render(request: InkSignPdfPageTurnPreviewRequest) -> UIImage? {
    let size = request.size
    guard size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return nil }
    guard let document = PDFDocument(url: request.sourceURL),
          let page = document.page(at: request.key.targetPageIndex),
          let pageRef = page.pageRef,
          let drawing = try? PKDrawing(data: request.drawingData) else { return nil }
    let mediaBox = page.bounds(for: .mediaBox)
    guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    // `size` is already in UIKit points. The renderer applies this scale once.
    format.scale = max(request.key.density, 1)
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { context in
      UIColor.white.setFill()
      context.cgContext.fill(CGRect(origin: .zero, size: size))
      let pdfToPreview = pageRef.getDrawingTransform(
        .mediaBox,
        rect: CGRect(origin: .zero, size: size),
        rotate: page.rotation,
        preserveAspectRatio: true)
      context.cgContext.saveGState()
      context.cgContext.concatenate(pdfToPreview)
      context.cgContext.drawPDFPage(pageRef)
      context.cgContext.restoreGState()

      _ = InkSignPdfCompatibilityTextRenderer.drawForPreview(
        request.compatibilityTextRuns,
        pageSize: mediaBox.size,
        mediaBox: mediaBox,
        pdfToPreview: pdfToPreview,
        in: context.cgContext)

      // Canonical ink is zero-origin, top-left page space. Move it into the
      // PDF media box and flip it before applying the same page presentation.
      let canonicalToPDF = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                             tx: mediaBox.minX, ty: mediaBox.maxY)
      context.cgContext.saveGState()
      context.cgContext.concatenate(pdfToPreview.concatenating(canonicalToPDF))
      drawing.image(from: CGRect(origin: .zero, size: mediaBox.size), scale: 1)
        .draw(in: CGRect(origin: .zero, size: mediaBox.size))
      context.cgContext.restoreGState()

      _ = InkSignPdfTextRenderer.drawForPreview(
        request.textAnnotations,
        pageSize: mediaBox.size,
        mediaBox: mediaBox,
        pdfToPreview: pdfToPreview,
        in: context.cgContext)
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
