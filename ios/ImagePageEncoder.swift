import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct InkSignPdfEncodedImage {
  let data: Data
  let pageSize: CGSize
  let rotation: Int
  let placement: CGAffineTransform

  var nativeInput: InkSignPdfPdfiumInput {
    InkSignPdfPdfiumInput(imageData: data, pageSize: pageSize, rotation: rotation,
      placement: placement)
  }
}

/// Preserves supported compressed images; rasterizes only for resolution or encoding changes.
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
    let grayscalePng = try isGrayscalePng4(url)
    let jpeg = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
    let supported = jpeg || grayscalePng
    let pointsPerSourcePixel = min(Double(pageWidth) / orientedWidth, Double(pageHeight) / orientedHeight)
    let sourceDpi = pointsPerInch / pointsPerSourcePixel
    let rasterDpi = min(targetDpi ?? (supported ? sourceDpi : dpi), sourceDpi)

    let pixelsPerPoint = min(rasterDpi / pointsPerInch,
                             maximumDimension / Double(max(pageWidth, pageHeight)))
    let targetWidth = min(Int(maximumDimension), max(1, Int(ceil(Double(pageWidth) * pixelsPerPoint))))
    let targetHeight = min(Int(maximumDimension), max(1, Int(ceil(Double(pageHeight) * pixelsPerPoint))))
    let imageTargetWidth = ceil(orientedWidth * pointsPerSourcePixel * pixelsPerPoint)
    let imageTargetHeight = ceil(orientedHeight * pointsPerSourcePixel * pixelsPerPoint)
    if supported, jpegQuality == nil,
       targetDpi == nil || (orientedWidth <= imageTargetWidth && orientedHeight <= imageTargetHeight) {
      return InkSignPdfEncodedImage(data: try Data(contentsOf: url),
        pageSize: CGSize(width: pageWidth, height: pageHeight), rotation: geometry.rotation,
        placement: preservedPlacement(orientation: orientation,
          width: orientedWidth * pointsPerSourcePixel, height: orientedHeight * pointsPerSourcePixel,
          pageWidth: Double(pageWidth), pageHeight: Double(pageHeight)))
    }
    let keepGrayscale = grayscalePng && jpegQuality == nil
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
            space: keepGrayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: keepGrayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
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
    if keepGrayscale {
      let pixels = Data(bytes: context.data!, count: context.bytesPerRow * targetHeight)
      let data = try InkSignPdfPdfiumBackend.encodeGrayscalePng(pixels: pixels,
        width: targetWidth, height: targetHeight, rowStride: context.bytesPerRow)
      return InkSignPdfEncodedImage(data: data,
        pageSize: CGSize(width: pageWidth, height: pageHeight), rotation: geometry.rotation,
        placement: CGAffineTransform(scaleX: pageWidth, y: pageHeight))
    }
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
    return InkSignPdfEncodedImage(data: data as Data,
      pageSize: CGSize(width: pageWidth, height: pageHeight), rotation: geometry.rotation,
      placement: CGAffineTransform(scaleX: pageWidth, y: pageHeight))
  }

  private static func preservedPlacement(orientation: UInt32, width: Double, height: Double,
                                         pageWidth: Double, pageHeight: Double) -> CGAffineTransform {
    let unit: CGAffineTransform
    switch orientation {
    case 2: unit = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
    case 3: unit = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
    case 4: unit = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
    case 5: unit = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
    case 6: unit = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
    case 7: unit = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    case 8: unit = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
    default: unit = .identity
    }
    return CGAffineTransform(a: unit.a * width, b: unit.b * height,
      c: unit.c * width, d: unit.d * height,
      tx: (pageWidth - width) / 2 + unit.tx * width,
      ty: (pageHeight - height) / 2 + unit.ty * height)
  }

  // Encoding admission only; the shared PNG/PDF boundary validates all chunks and samples.
  private static func isGrayscalePng4(_ url: URL) throws -> Bool {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    guard let data = try file.read(upToCount: 29), data.count == 29 else { return false }
    return data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) &&
      data[24] == 4 && data[25] == 0 && data[28] == 0
  }
}
