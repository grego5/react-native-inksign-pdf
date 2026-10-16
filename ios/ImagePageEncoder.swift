import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct InkSignPdfEncodedImage {
  let jpeg: Data
  let pageSize: CGSize
  let rotation: Int

  var nativeInput: InkSignPdfPdfiumInput {
    InkSignPdfPdfiumInput(imageData: jpeg, pageSize: pageSize, rotation: rotation,
      placement: CGAffineTransform(scaleX: pageSize.width, y: pageSize.height))
  }
}

/// Normalizes a selected image into a page-sized JPEG. The source is unchanged.
enum InkSignPdfImagePageEncoder {
  private static let dpi = 200.0
  private static let pointsPerInch = 72.0
  private static let maximumDimension = 8192.0

  static func encode(
    _ url: URL,
    geometry: PageGeometry,
    targetDpi: Double? = nil,
    jpegQuality: Double? = nil
  ) throws -> InkSignPdfEncodedImage {
    let pageWidth = geometry.mediaBox.width
    let pageHeight = geometry.mediaBox.height
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else {
      throw MutablePageError.unsupportedContent
    }

    guard let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let sourceWidth = (sourceProperties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
          let sourceHeight = (sourceProperties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue else {
      throw MutablePageError.unsupportedContent
    }
    let orientation = (sourceProperties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
    let swapsDimensions = (5...8).contains(Int(orientation))
    let orientedWidth = swapsDimensions ? sourceHeight : sourceWidth
    let orientedHeight = swapsDimensions ? sourceWidth : sourceHeight
    let rasterDpi: Double
    if let targetDpi {
      let pointsPerSourcePixel = min(
        Double(pageWidth) / orientedWidth,
        Double(pageHeight) / orientedHeight)
      rasterDpi = min(targetDpi, pointsPerInch / pointsPerSourcePixel)
    } else {
      rasterDpi = dpi
    }

    let pixelsPerPoint = min(rasterDpi / pointsPerInch,
                             maximumDimension / Double(max(pageWidth, pageHeight)))
    let targetWidth = max(1, Int(ceil(Double(pageWidth) * pixelsPerPoint)))
    let targetHeight = max(1, Int(ceil(Double(pageHeight) * pixelsPerPoint)))
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
      throw MutablePageError.unsupportedContent
    }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    context.interpolationQuality = .high
    let fitScale = min(CGFloat(targetWidth) / CGFloat(image.width),
                       CGFloat(targetHeight) / CGFloat(image.height))
    let drawnSize = CGSize(width: CGFloat(image.width) * fitScale,
                           height: CGFloat(image.height) * fitScale)
    let target = CGRect(
      x: (CGFloat(targetWidth) - drawnSize.width) / 2,
      y: (CGFloat(targetHeight) - drawnSize.height) / 2,
      width: drawnSize.width,
      height: drawnSize.height)
    context.draw(image, in: target)
    guard let normalized = context.makeImage() else {
      throw MutablePageError.unsupportedContent
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MutablePageError.unsupportedContent
    }
    CGImageDestinationAddImage(destination, normalized,
                              [kCGImageDestinationLossyCompressionQuality: jpegQuality ?? 0.72] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw MutablePageError.unsupportedContent
    }
    return InkSignPdfEncodedImage(jpeg: data as Data,
      pageSize: CGSize(width: pageWidth, height: pageHeight), rotation: geometry.rotation)
  }
}
