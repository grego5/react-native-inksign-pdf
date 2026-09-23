import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Normalizes a selected image into the page-sized JPEG consumed by the shared
/// PDFium assembler. The source is never rewritten.
enum InkSignPdfMutablePageImageEncoder {
  private static let dpi = 200.0
  private static let pointsPerInch = 72.0
  private static let maximumDimension = 8192.0

  static func encode(_ url: URL, geometry: PageGeometry) throws -> [String: Any] {
    let pageWidth = geometry.mediaBox.width
    let pageHeight = geometry.mediaBox.height
    guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0,
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else {
      throw InkSignView.MutablePageError.unsupportedContent
    }

    let targetWidth = pixelDimension(pageWidth)
    let targetHeight = pixelDimension(pageHeight)
    let maxPixel = max(targetWidth, targetHeight)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    context.interpolationQuality = .high
    let scale = min(CGFloat(targetWidth) / CGFloat(image.width),
                    CGFloat(targetHeight) / CGFloat(image.height))
    let drawnSize = CGSize(width: CGFloat(image.width) * scale,
                           height: CGFloat(image.height) * scale)
    let target = CGRect(
      x: (CGFloat(targetWidth) - drawnSize.width) / 2,
      y: (CGFloat(targetHeight) - drawnSize.height) / 2,
      width: drawnSize.width,
      height: drawnSize.height)
    context.draw(image, in: target)
    guard let normalized = context.makeImage() else {
      throw InkSignView.MutablePageError.unsupportedContent
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, normalized,
                              [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw InkSignView.MutablePageError.unsupportedContent
    }
    return [
      "type": "image",
      "data": data as Data,
      "pageWidth": pageWidth,
      "pageHeight": pageHeight,
      "a": pageWidth,
      "d": pageHeight,
    ]
  }

  private static func pixelDimension(_ points: CGFloat) -> Int {
    Int(min(max(ceil(Double(points) * dpi / pointsPerInch), 1), maximumDimension))
  }
}
