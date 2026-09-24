import CoreGraphics
import PencilKit
import UIKit

struct InkSignPdfFilledStroke {
  let path: CGPath
  let color: UIColor
}

enum InkSignPdfSignatureVectorPath {
  // PencilKit distance interpolation can quantize an opaque sample to 65534/65535.
  private static let opaqueOpacityQuantizationStep = CGFloat(1) / CGFloat(UInt16.max)

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
    guard stroke.ink.inkType == .pen, stroke.mask == nil else { throw Error.unsupportedInk }

    let strokePath = stroke.path
    guard strokePath.count > 0 else { throw Error.invalidStroke("empty path") }
    var samples: [Sample] = []
    samples.reserveCapacity(strokePath.count)
    for point in strokePath.interpolatedPoints(by: .distance(1)) {
      let sample = Sample(center: point.location,
                          radius: point.size.width / 2,
                          opacity: point.opacity)
      if let previous = samples.last, previous.center == sample.center {
        samples[samples.count - 1] = Sample(
          center: sample.center,
          radius: max(previous.radius, sample.radius),
          opacity: sample.opacity)
      } else {
        samples.append(sample)
      }
    }
    guard !samples.isEmpty else { throw Error.invalidStroke("no interpolated samples") }
    for (index, sample) in samples.enumerated() {
      guard abs(sample.opacity - 1) <= opaqueOpacityQuantizationStep else {
        throw Error.invalidStroke("sample \(index) has opacity \(sample.opacity)")
      }
      guard sample.radius.isFinite, sample.radius > 0,
            sample.center.x.isFinite, sample.center.y.isFinite else {
        throw Error.invalidStroke("sample \(index) has invalid size or location")
      }
    }

    let outline: CGMutablePath
    if samples.count == 1 {
      let sample = samples[0]
      outline = CGMutablePath(ellipseIn: CGRect(x: sample.center.x - sample.radius,
                                                y: sample.center.y - sample.radius,
                                                width: sample.radius * 2,
                                                height: sample.radius * 2),
                              transform: nil)
    } else {
      outline = try variableWidthOutline(samples)
    }

    var transform = stroke.transform
    guard let transformed = outline.copy(using: &transform) else {
      throw Error.invalidStroke("stroke transform could not be applied")
    }
    return InkSignPdfFilledStroke(path: transformed, color: stroke.ink.color)
  }

  private static func variableWidthOutline(_ samples: [Sample]) throws -> CGMutablePath {
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    left.reserveCapacity(samples.count)
    right.reserveCapacity(samples.count)

    for index in samples.indices {
      let previous = samples[max(index - 1, 0)].center
      let next = samples[min(index + 1, samples.count - 1)].center
      let current = samples[index].center
      var tangent = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
      var length = hypot(tangent.x, tangent.y)
      if length == 0 {
        tangent = CGPoint(x: next.x - current.x, y: next.y - current.y)
        length = hypot(tangent.x, tangent.y)
      }
      if length == 0 {
        tangent = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        length = hypot(tangent.x, tangent.y)
      }
      guard length.isFinite, length > 0 else {
        throw Error.invalidStroke("sample \(index) has no distinct neighbor")
      }
      let normal = CGPoint(x: -tangent.y / length, y: tangent.x / length)
      let sample = samples[index]
      left.append(CGPoint(x: sample.center.x + normal.x * sample.radius,
                          y: sample.center.y + normal.y * sample.radius))
      right.append(CGPoint(x: sample.center.x - normal.x * sample.radius,
                           y: sample.center.y - normal.y * sample.radius))
    }

    let path = CGMutablePath()
    path.move(to: left[0])
    for point in left.dropFirst() { path.addLine(to: point) }

    let end = samples[samples.count - 1]
    appendArc(center: end.center,
              radius: end.radius,
              start: left[left.count - 1],
              sweep: -.pi,
              to: path)

    for point in right.dropLast().reversed() { path.addLine(to: point) }

    let start = samples[0]
    appendArc(center: start.center,
              radius: start.radius,
              start: right[0],
              sweep: .pi,
              to: path)
    path.closeSubpath()
    return path
  }

  private static func appendArc(center: CGPoint,
                                radius: CGFloat,
                                start: CGPoint,
                                sweep: CGFloat,
                                to path: CGMutablePath) {
    let startAngle = atan2(start.y - center.y, start.x - center.x)
    for step in 1...8 {
      let angle = startAngle + sweep * CGFloat(step) / 8
      path.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius))
    }
  }

  private struct Sample {
    let center: CGPoint
    let radius: CGFloat
    let opacity: CGFloat
  }
}
