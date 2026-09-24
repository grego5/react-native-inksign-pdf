import CoreGraphics
import Foundation
import PencilKit
import XCTest
@testable import ReactNativeInkSignPdf

final class SignatureVectorPathTests: XCTestCase {
  func testSweptStrokeRetainsRecordedWidthsAndCompleteEndpointFootprints() throws {
    let drawing = straightVariableWidthDrawing()
    let stroke = try XCTUnwrap(drawing.strokes.first)
    let samples = Array(stroke.path.interpolatedPoints(by: .distance(1)))
    let path = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: drawing).first).path
    let narrow = try XCTUnwrap(samples.min { $0.size.width < $1.size.width })
    let wide = try XCTUnwrap(samples.max { $0.size.width < $1.size.width })

    XCTAssertTrue(path.contains(CGPoint(x: narrow.location.x,
                                        y: narrow.location.y + narrow.size.width * 0.4)))
    XCTAssertTrue(path.contains(CGPoint(x: wide.location.x,
                                        y: wide.location.y + wide.size.width * 0.4)))
    let narrowReach = verticalReach(of: path, at: narrow.location)
    let wideReach = verticalReach(of: path, at: wide.location)
    XCTAssertEqual(narrowReach, narrow.size.width / 2, accuracy: 1.2)
    XCTAssertEqual(wideReach, wide.size.width / 2, accuracy: 1.2)
    XCTAssertGreaterThan(wideReach, narrowReach * 3)

    assertEndpointCaps(in: path, points: samples)

    let rightToLeft = drawing(points: [
      strokePoint(x: 250, y: 180, size: 4, time: 0),
      strokePoint(x: 200, y: 180, size: 8, time: 0.1),
      strokePoint(x: 150, y: 180, size: 20, time: 0.2),
      strokePoint(x: 100, y: 180, size: 8, time: 0.3),
      strokePoint(x: 50, y: 180, size: 4, time: 0.4),
    ])
    let rightToLeftSamples = Array(try XCTUnwrap(rightToLeft.strokes.first)
      .path.interpolatedPoints(by: .distance(1)))
    let rightToLeftPath = try XCTUnwrap(
      InkSignPdfSignatureVectorPath.filledStrokes(in: rightToLeft).first).path
    assertEndpointCaps(in: rightToLeftPath, points: rightToLeftSamples)
  }

  func testDotsShortStrokesTightTurnsAndReversalsRemainFilled() throws {
    let dot = drawing(points: [strokePoint(x: 100, y: 100, size: 12, time: 0)])
    let short = drawing(points: [
      strokePoint(x: 100, y: 100, size: 8, time: 0),
      strokePoint(x: 100.4, y: 100.2, size: 8, time: 0.01),
    ])
    let turnPoints = [
      strokePoint(x: 60, y: 60, size: 10, time: 0),
      strokePoint(x: 120, y: 60, size: 10, time: 0.1),
      strokePoint(x: 120, y: 120, size: 10, time: 0.2),
      strokePoint(x: 80, y: 120, size: 10, time: 0.3),
      strokePoint(x: 80, y: 80, size: 10, time: 0.4),
      strokePoint(x: 140, y: 80, size: 10, time: 0.5),
    ]
    let turn = drawing(points: turnPoints)
    let reversed = drawing(points: Array(turnPoints.reversed().enumerated().map { index, point in
      strokePoint(x: point.location.x, y: point.location.y,
                  size: point.size.width, time: Double(index) * 0.1)
    }))

    let dotPath = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: dot).first).path
    XCTAssertEqual(verticalReach(of: dotPath, at: CGPoint(x: 100, y: 100)), 6, accuracy: 0.2)

    for (drawing, hasUsefulEndpointSpacing) in [(dot, true), (short, false),
                                                (turn, true), (reversed, true)] {
      let stroke = try XCTUnwrap(drawing.strokes.first)
      let points = Array(stroke.path.interpolatedPoints(by: .distance(1)))
      let path = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: drawing).first).path
      XCTAssertFalse(path.boundingBoxOfPath.isEmpty)
      for point in points {
        XCTAssertTrue(path.contains(point.location), "Every retained point footprint must be filled.")
      }
      if hasUsefulEndpointSpacing { assertEndpointCaps(in: path, points: points) }
      for pair in zip(points, points.dropFirst()) {
        let midpoint = CGPoint(x: (pair.0.location.x + pair.1.location.x) / 2,
                               y: (pair.0.location.y + pair.1.location.y) / 2)
        XCTAssertTrue(path.contains(midpoint), "Adjacent footprints must have a filled connector.")
      }
      for endpoint in [points[0], points[points.count - 1]] {
        XCTAssertTrue(path.contains(CGPoint(x: endpoint.location.x,
                                            y: endpoint.location.y + endpoint.size.height * 0.4)))
      }
    }

    let forwardPath = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: turn).first).path
    let reversePath = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(
      in: reversed).first).path
    assertBounds(reversePath.boundingBoxOfPath, equals: forwardPath.boundingBoxOfPath)
  }

  func testStrokeTransformIsAppliedOnceToCompletedContour() throws {
    let controlPoint = strokePoint(x: 100, y: 100, size: 12, time: 0)
    let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                          path: PKStrokePath(controlPoints: [controlPoint], creationDate: Date()),
                          transform: CGAffineTransform(translationX: 15, y: -7),
                          mask: nil)
    let path = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(
      in: PKDrawing(strokes: [stroke])).first).path
    assertBounds(path.boundingBoxOfPath,
                 equals: CGRect(x: 109, y: 87, width: 12, height: 12))
  }

  func testTransparentPenInkIsRejected() throws {
    let point = strokePoint(x: 100, y: 100, size: 12, time: 0)
    let stroke = PKStroke(ink: PKInk(.pen, color: .black.withAlphaComponent(0.5)),
                          path: PKStrokePath(controlPoints: [point], creationDate: Date()),
                          transform: .identity,
                          mask: nil)
    XCTAssertThrowsError(try InkSignPdfSignatureVectorPath.filledStrokes(
      in: PKDrawing(strokes: [stroke]))) { error in
      guard case InkSignPdfSignatureVectorPath.Error.unsupportedInk = error else {
        return XCTFail("Transparent pen ink must fail as unsupported: \(error)")
      }
    }
  }

  func testDistinctNarrowSamplesAreConnectedByFilledVectorGeometry() throws {
    let narrowPoint = { (x: CGFloat, time: Double) in
      PKStrokePoint(location: CGPoint(x: x, y: 100),
                    timeOffset: time,
                    size: CGSize(width: 0.2, height: 0.2),
                    opacity: 1,
                    force: 0.5,
                    azimuth: 0,
                    altitude: .pi / 2)
    }
    let stroke = drawing(points: [narrowPoint(100, 0), narrowPoint(120, 0.2)])
    let path = try XCTUnwrap(InkSignPdfSignatureVectorPath.filledStrokes(in: stroke).first).path

    XCTAssertTrue(path.contains(CGPoint(x: 110, y: 100)),
                  "The filled connector must bridge distinct centers beyond their circular footprints.")
  }

  func testNonCircularFootprintsAreRejectedAndDuplicateCentersKeepLargestDiameter() throws {
    let nonCircularPoint = PKStrokePoint(location: CGPoint(x: 100, y: 100),
                                         timeOffset: 0,
                                         size: CGSize(width: 20, height: 6),
                                         opacity: 1,
                                         force: 0.1,
                                         azimuth: 0,
                                         altitude: .pi / 2)
    XCTAssertThrowsError(try InkSignPdfSignatureVectorPath.filledStrokes(
      in: drawing(points: [nonCircularPoint]))) { error in
      guard case InkSignPdfSignatureVectorPath.Error.unsupportedInk = error else {
        return XCTFail("Non-circular pen footprints must fail as unsupported ink: \(error)")
      }
    }

    let center = CGPoint(x: 100, y: 140)
    let duplicate = drawing(points: [
      strokePoint(x: center.x, y: center.y, size: 4, time: 0),
      strokePoint(x: center.x, y: center.y, size: 20, time: 0.1),
      strokePoint(x: 160, y: center.y, size: 4, time: 0.2),
    ])
    let samples = Array(try XCTUnwrap(duplicate.strokes.first)
      .path.interpolatedPoints(by: .distance(1)))
    let largestAtCenter = try XCTUnwrap(samples.filter { $0.location == center }
      .max { $0.size.width < $1.size.width })
    let duplicatePath = try XCTUnwrap(
      InkSignPdfSignatureVectorPath.filledStrokes(in: duplicate).first).path
    XCTAssertEqual(verticalReach(of: duplicatePath, at: center),
                   largestAtCenter.size.width / 2,
                   accuracy: 1.2)
  }

  private func straightVariableWidthDrawing() -> PKDrawing {
    drawing(points: [
      strokePoint(x: 50, y: 180, size: 4, time: 0),
      strokePoint(x: 100, y: 180, size: 8, time: 0.1),
      strokePoint(x: 150, y: 180, size: 20, time: 0.2),
      strokePoint(x: 200, y: 180, size: 8, time: 0.3),
      strokePoint(x: 250, y: 180, size: 4, time: 0.4),
    ])
  }

  private func drawing(points: [PKStrokePoint]) -> PKDrawing {
    let path = PKStrokePath(controlPoints: points, creationDate: Date())
    let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                          path: path,
                          transform: .identity,
                          mask: nil)
    return PKDrawing(strokes: [stroke])
  }

  private func strokePoint(x: CGFloat, y: CGFloat, size: CGFloat, time: Double) -> PKStrokePoint {
    PKStrokePoint(location: CGPoint(x: x, y: y),
                  timeOffset: time,
                  size: CGSize(width: size, height: size),
                  opacity: 1,
                  force: 0.5,
                  azimuth: 0,
                  altitude: .pi / 2)
  }

  private func verticalReach(of path: CGPath, at point: CGPoint) -> CGFloat {
    var inside: CGFloat = 0
    var outside: CGFloat = 40
    for _ in 0..<20 {
      let candidate = (inside + outside) / 2
      if path.contains(CGPoint(x: point.x, y: point.y + candidate)) {
        inside = candidate
      } else {
        outside = candidate
      }
    }
    return (inside + outside) / 2
  }

  private func assertEndpointCaps(in path: CGPath, points: [PKStrokePoint],
                                  file: StaticString = #filePath, line: UInt = #line) {
    guard let first = points.first, let last = points.last else {
      XCTFail("A stroke must retain endpoint samples.", file: file, line: line)
      return
    }
    let endpointDirections: [(PKStrokePoint, CGPoint)]
    if points.count == 1 {
      endpointDirections = [(first, CGPoint(x: 1, y: 0)), (last, CGPoint(x: 1, y: 0))]
    } else {
      let next = points[1].location
      let previous = points[points.count - 2].location
      endpointDirections = [
        (first, CGPoint(x: first.location.x - next.x, y: first.location.y - next.y)),
        (last, CGPoint(x: last.location.x - previous.x, y: last.location.y - previous.y)),
      ]
    }
    for (endpoint, outward) in endpointDirections {
      let length = hypot(outward.x, outward.y)
      let direction = CGPoint(x: outward.x / length, y: outward.y / length)
      let radius = endpoint.size.width / 2
      let inside = CGPoint(x: endpoint.location.x + direction.x * radius * 0.8,
                           y: endpoint.location.y + direction.y * radius * 0.8)
      let outside = CGPoint(x: endpoint.location.x + direction.x * radius * 1.2,
                            y: endpoint.location.y + direction.y * radius * 1.2)
      XCTAssertTrue(path.contains(inside), "The full endpoint footprint must be filled.",
                    file: file, line: line)
      XCTAssertFalse(path.contains(outside), "The cap must end at the recorded footprint.",
                     file: file, line: line)
    }
  }

  private func assertBounds(_ actual: CGRect, equals expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
  }
}
