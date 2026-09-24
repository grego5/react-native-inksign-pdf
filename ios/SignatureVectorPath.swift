import CoreGraphics
import PencilKit
import UIKit

struct InkSignPdfFilledStroke {
  let path: CGPath
  let color: UIColor
}

enum InkSignPdfSignatureVectorPath {
  enum Error: Swift.Error {
    case unsupportedInk
    case invalidStroke
  }

  static func filledStrokes(in drawing: PKDrawing) throws -> [InkSignPdfFilledStroke] {
    try drawing.strokes.map(filledStroke)
  }

  private static func filledStroke(_ stroke: PKStroke) throws -> InkSignPdfFilledStroke {
    guard stroke.ink.inkType == .pen, stroke.mask == nil else { throw Error.unsupportedInk }

    let strokePath = stroke.path
    guard strokePath.count > 0 else { throw Error.invalidStroke }
    let parameterRange = PKFloatRange(lowerBound: 0,
                                      upperBound: CGFloat(strokePath.count - 1))
    var samples: [Sample] = []
    strokePath.enumerateInterpolatedPoints(in: parameterRange,
                                           strideByDistance: 1) { point, _ in
      samples.append(Sample(center: point.location,
                            radius: point.size.width / 2,
                            opacity: point.opacity))
    }
    if strokePath.count == 1 && samples.isEmpty {
      let point = strokePath.point(at: 0)
      samples.append(Sample(center: point.location,
                            radius: point.size.width / 2,
                            opacity: point.opacity))
    }
    guard !samples.isEmpty,
          samples.allSatisfy({ $0.opacity == 1 &&
            $0.radius.isFinite && $0.radius > 0 &&
            $0.center.x.isFinite && $0.center.y.isFinite }) else {
      throw Error.invalidStroke
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
    guard let transformed = outline.copy(using: &transform) else { throw Error.invalidStroke }
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
      let tangent = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
      let length = hypot(tangent.x, tangent.y)
      guard length.isFinite, length > 0 else { throw Error.invalidStroke }
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
