import CoreGraphics
import PencilKit
import UIKit

struct InkSignPdfFilledStroke {
  let path: CGPath
  let color: UIColor
}

enum InkSignPdfSignatureVectorPath {
  // Distance interpolation can quantize an opaque sample to 65534/65535.
  private static let opaqueOpacityQuantizationStep = CGFloat(1) / CGFloat(UInt16.max)
  private static let circleControlRatio = CGFloat(0.5522847498307936)

  enum Error: Swift.Error, CustomStringConvertible {
    case unsupportedInk
    case invalidStroke(String)

    var description: String {
      switch self {
      case .unsupportedInk:
        return "unsupportedInk"
      case .invalidStroke(let reason):
        return "invalidStroke(\(reason))"
      }
    }
  }

  static func filledStrokes(in drawing: PKDrawing) throws -> [InkSignPdfFilledStroke] {
    try drawing.strokes.map(filledStroke)
  }

  private static func filledStroke(_ stroke: PKStroke) throws -> InkSignPdfFilledStroke {
    guard stroke.ink.inkType == .pen, stroke.mask == nil,
          stroke.ink.color.cgColor.alpha == 1 else { throw Error.unsupportedInk }

    let strokePath = stroke.path
    guard strokePath.count > 0 else { throw Error.invalidStroke("empty path") }
    var samples: [Sample] = []
    samples.reserveCapacity(strokePath.count)
    for point in strokePath.interpolatedPoints(by: .distance(1)) {
      let sample = Sample(center: point.location, diameter: point.size.width)
      guard abs(point.opacity - 1) <= opaqueOpacityQuantizationStep else {
        throw Error.unsupportedInk
      }
      guard sample.center.x.isFinite, sample.center.y.isFinite,
            sample.diameter.isFinite, sample.diameter > 0,
            point.size.height.isFinite, point.size.height > 0 else {
        throw Error.invalidStroke("interpolated sample has invalid size or location")
      }
      guard point.size.width == point.size.height else { throw Error.unsupportedInk }

      if let previous = samples.last, previous.center == sample.center {
        samples[samples.count - 1] = Sample(center: sample.center,
                                             diameter: max(previous.diameter, sample.diameter))
      } else {
        samples.append(sample)
      }
    }
    guard !samples.isEmpty else { throw Error.invalidStroke("no interpolated samples") }

    let outline = try sweptOutline(samples)
    var transform = stroke.transform
    guard let transformed = outline.copy(using: &transform) else {
      throw Error.invalidStroke("stroke transform could not be applied")
    }
    return InkSignPdfFilledStroke(path: transformed, color: stroke.ink.color)
  }

  private static func sweptOutline(_ samples: [Sample]) throws -> CGMutablePath {
    let path = CGMutablePath()
    for sample in samples {
      appendCircle(at: sample.center, diameter: sample.diameter, to: path)
    }
    for index in 1..<samples.count {
      try appendConnector(from: samples[index - 1], to: samples[index], path)
    }
    return path
  }

  private static func appendCircle(at center: CGPoint,
                                   diameter: CGFloat,
                                   to path: CGMutablePath) {
    let radius = diameter / 2
    let control = radius * circleControlRatio

    path.move(to: CGPoint(x: center.x + radius, y: center.y))
    path.addCurve(to: CGPoint(x: center.x, y: center.y + radius),
                  control1: CGPoint(x: center.x + radius, y: center.y + control),
                  control2: CGPoint(x: center.x + control, y: center.y + radius))
    path.addCurve(to: CGPoint(x: center.x - radius, y: center.y),
                  control1: CGPoint(x: center.x - control, y: center.y + radius),
                  control2: CGPoint(x: center.x - radius, y: center.y + control))
    path.addCurve(to: CGPoint(x: center.x, y: center.y - radius),
                  control1: CGPoint(x: center.x - radius, y: center.y - control),
                  control2: CGPoint(x: center.x - control, y: center.y - radius))
    path.addCurve(to: CGPoint(x: center.x + radius, y: center.y),
                  control1: CGPoint(x: center.x + control, y: center.y - radius),
                  control2: CGPoint(x: center.x + radius, y: center.y - control))
    path.closeSubpath()
  }

  private static func appendConnector(from start: Sample,
                                      to end: Sample,
                                      _ path: CGMutablePath) throws {
    let dx = end.center.x - start.center.x
    let dy = end.center.y - start.center.y
    let distance = hypot(dx, dy)
    guard distance.isFinite, distance > 0 else {
      throw Error.invalidStroke("adjacent samples have no distinct locations")
    }
    let normal = CGPoint(x: -dy / distance, y: dx / distance)
    let startRadius = start.diameter / 2
    let endRadius = end.diameter / 2
    let startOffset = CGPoint(x: normal.x * startRadius, y: normal.y * startRadius)
    let endOffset = CGPoint(x: normal.x * endRadius, y: normal.y * endRadius)
    let points = [
      CGPoint(x: start.center.x + startOffset.x, y: start.center.y + startOffset.y),
      CGPoint(x: end.center.x + endOffset.x, y: end.center.y + endOffset.y),
      CGPoint(x: end.center.x - endOffset.x, y: end.center.y - endOffset.y),
      CGPoint(x: start.center.x - startOffset.x, y: start.center.y - startOffset.y),
    ]
    let orderedPoints = signedArea(points) >= 0 ? points : Array(points.reversed())
    path.move(to: orderedPoints[0])
    for point in orderedPoints.dropFirst() { path.addLine(to: point) }
    path.closeSubpath()
  }

  private static func signedArea(_ points: [CGPoint]) -> CGFloat {
    guard points.count > 2 else { return 0 }
    return points.indices.reduce(into: CGFloat.zero) { area, index in
      let point = points[index]
      let next = points[(index + 1) % points.count]
      area += point.x * next.y - next.x * point.y
    }
  }

  private struct Sample {
    let center: CGPoint
    let diameter: CGFloat
  }
}
