import CoreGraphics
import Foundation

struct InkSignPdfPlacementRule: Equatable {
  let minX: CGFloat
  let maxX: CGFloat
  let y: CGFloat
}

enum InkSignPdfPlacementRuleDetector {
  private struct GraphicsState {
    var transform = CGAffineTransform.identity
    var lineWidth: CGFloat = 1
  }

  private struct Subpath {
    var points: [CGPoint]
    var rectangles: [CGRect]
    var curved = false
  }

  private final class ScanState {
    let pageSize: CGSize
    let pdfToPageTransform: CGAffineTransform
    let operatorTable: CGPDFOperatorTableRef
    var graphics = GraphicsState()
    var graphicsStack: [GraphicsState] = []
    var subpaths: [Subpath] = []
    var filledRectangles: [CGRect] = []
    var horizontalLines: [InkSignPdfPlacementRule] = []
    var verticalLines: [CGRect] = []
    private var formDepth = 0

    init(pageSize: CGSize,
         pdfToPageTransform: CGAffineTransform,
         operatorTable: CGPDFOperatorTableRef) {
      self.pageSize = pageSize
      self.pdfToPageTransform = pdfToPageTransform
      self.operatorTable = operatorTable
    }

    func scan(_ stream: CGPDFContentStreamRef) {
      let scanner = CGPDFScannerCreate(stream, operatorTable,
                                       Unmanaged.passUnretained(self).toOpaque())
      CGPDFScannerScan(scanner)
    }

    func scanForm(named name: String, in scanner: CGPDFScannerRef) {
      guard formDepth < 8 else { return }
      let parent = CGPDFScannerGetContentStream(scanner)
      guard let object = CGPDFContentStreamGetResource(parent, "XObject", name),
            CGPDFObjectGetType(object) == .stream else { return }
      var form: CGPDFStreamRef?
      guard CGPDFObjectGetValue(object, .stream, &form), let form,
            let dictionary = CGPDFStreamGetDictionary(form) else { return }
      var subtype: UnsafePointer<CChar>?
      guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
            subtype.map(String.init(cString:)) == "Form" else { return }
      var resources: CGPDFDictionaryRef?
      guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
            let resources else { return }
      var matrix = CGAffineTransform.identity
      var matrixValues: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixValues),
         let matrixValues, CGPDFArrayGetCount(matrixValues) == 6 {
        var values = [CGFloat](repeating: 0, count: 6)
        for index in values.indices {
          var value: CGPDFReal = 0
          guard CGPDFArrayGetNumber(matrixValues, index, &value) else { return }
          values[index] = CGFloat(value)
        }
        matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                   d: values[3], tx: values[4], ty: values[5])
      }
      let formContent = CGPDFContentStreamCreateWithStream(form, resources, parent)
      let previousGraphics = graphics
      let previousGraphicsStack = graphicsStack
      let previousSubpaths = subpaths
      graphics.transform = matrix.concatenating(graphics.transform)
      graphicsStack = []
      subpaths = []
      formDepth += 1
      scan(formContent)
      formDepth -= 1
      graphics = previousGraphics
      graphicsStack = previousGraphicsStack
      subpaths = previousSubpaths
    }

    private func canonicalPoint(_ point: CGPoint) -> CGPoint {
      let pagePoint = point.applying(pdfToPageTransform)
      return CGPoint(x: pagePoint.x, y: pageSize.height - pagePoint.y)
    }

    func beginSubpath(at point: CGPoint) {
      subpaths.append(Subpath(points: [canonicalPoint(point.applying(graphics.transform))],
                              rectangles: []))
    }

    func appendLine(to point: CGPoint) {
      guard !subpaths.isEmpty else { return }
      subpaths[subpaths.count - 1].points.append(canonicalPoint(point.applying(graphics.transform)))
    }

    func appendCurve() {
      guard !subpaths.isEmpty else { return }
      subpaths[subpaths.count - 1].curved = true
    }

    func appendRectangle(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
      let corners = [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
                     CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        .map { canonicalPoint($0.applying(graphics.transform)) }
      let bounds = InkSignPdfPlacementRuleDetector.bounds(of: corners)
      guard !corners.isEmpty else { return }
      var path = Subpath(points: corners, rectangles: [bounds])
      path.points.append(corners[0])
      subpaths.append(path)
    }

    func closeSubpath() {
      guard let first = subpaths.last?.points.first else { return }
      subpaths[subpaths.count - 1].points.append(first)
    }

    func paint(stroke: Bool, fill: Bool) {
      if stroke {
        let scaleX = hypot(graphics.transform.a, graphics.transform.b) *
          hypot(pdfToPageTransform.a, pdfToPageTransform.b)
        let scaleY = hypot(graphics.transform.c, graphics.transform.d) *
          hypot(pdfToPageTransform.c, pdfToPageTransform.d)
        let strokeWidth = graphics.lineWidth * max(scaleX, scaleY)
        for subpath in subpaths where !subpath.curved {
          let bounds = InkSignPdfPlacementRuleDetector.bounds(of: subpath.points)
          if bounds.width <= max(0.75, strokeWidth * 0.75), bounds.height >= 36 {
            verticalLines.append(bounds)
            continue
          }
          guard let extent = InkSignPdfPlacementRuleDetector.horizontalExtent(
            subpath.points, tolerance: max(0.75, strokeWidth * 0.75)) else {
            continue
          }
          let length = extent.maxX - extent.minX
          guard length >= 36,
                extent.minX >= 1,
                extent.maxX <= pageSize.width - 1,
                extent.y >= 1,
                extent.y <= pageSize.height - 1,
                length <= pageSize.width * 0.96 else { continue }
          horizontalLines.append(InkSignPdfPlacementRule(
            minX: extent.minX,
            maxX: extent.maxX,
            y: extent.y))
        }
      }
      if fill {
        for subpath in subpaths where !subpath.curved {
          let rectangles = subpath.rectangles.isEmpty
            ? [InkSignPdfPlacementRuleDetector.rectangularBounds(of: subpath.points)].compactMap { $0 }
            : subpath.rectangles
          for rectangle in rectangles where InkSignPdfPlacementRuleDetector.isSmallRectangle(rectangle) {
            filledRectangles.append(rectangle)
          }
        }
      }
      subpaths.removeAll(keepingCapacity: true)
    }

    func rules(pageSize: CGSize) -> [InkSignPdfPlacementRule] {
      let dots = InkSignPdfPlacementRuleDetector.rectangleRows(filledRectangles)
      let uncrossedLines = horizontalLines.filter { line in
        !verticalLines.contains { vertical in
          vertical.minY <= line.y && line.y <= vertical.maxY &&
            (abs(vertical.minX - line.minX) < 1.5 ||
             abs(vertical.minX - line.maxX) < 1.5 ||
             (vertical.minX > line.minX && vertical.minX < line.maxX))
        }
      }
      let all = uncrossedLines + dots
      return all.filter { rule in
        rule.minX >= 0 && rule.maxX <= pageSize.width &&
          rule.y > 8 && rule.y < pageSize.height - 8 && rule.maxX - rule.minX >= 36
      }.sorted {
        $0.y == $1.y ? $0.minX < $1.minX : $0.y < $1.y
      }
    }
  }

  static func scan(url: URL, pageIndex: Int, mediaBox: CGRect) -> [InkSignPdfPlacementRule] {
    guard let document = CGPDFDocument(url as CFURL),
          let page = document.page(at: pageIndex + 1) else { return [] }
    return scan(page: page, mediaBox: mediaBox)
  }

  static func scan(page: CGPDFPage, mediaBox: CGRect) -> [InkSignPdfPlacementRule] {
    guard mediaBox.width > 0, mediaBox.height > 0,
          let table = CGPDFOperatorTableCreate() else { return [] }
    let stream = CGPDFContentStreamCreateWithPage(page)
    let pageBounds = CGRect(origin: .zero, size: mediaBox.size)
    let pdfToPageTransform = page.getDrawingTransform(.mediaBox,
                                                      rect: pageBounds,
                                                      rotate: 0,
                                                      preserveAspectRatio: false)
    let state = ScanState(pageSize: mediaBox.size,
                          pdfToPageTransform: pdfToPageTransform,
                          operatorTable: table)
    registerCallbacks(on: table)
    state.scan(stream)
    return state.rules(pageSize: mediaBox.size)
  }

  private static func registerCallbacks(on table: CGPDFOperatorTableRef) {
    CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
      Self.saveGraphicsState(scanner, info)
    }
    CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
      Self.restoreGraphicsState(scanner, info)
    }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
      Self.concatenateTransform(scanner, info)
    }
    CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
      Self.setLineWidth(scanner, info)
    }
    CGPDFOperatorTableSetCallback(table, "m") { scanner, info in Self.moveTo(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "l") { scanner, info in Self.lineTo(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "h") { scanner, info in Self.closePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "re") { scanner, info in Self.rectangle(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "c") { scanner, info in Self.cubicCurve(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "v") { scanner, info in Self.shortCubicCurve(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "y") { scanner, info in Self.shortCubicCurve(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "S") { scanner, info in Self.strokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "s") { scanner, info in Self.closeAndStrokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "f") { scanner, info in Self.fillPath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "F") { scanner, info in Self.fillPath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "f*") { scanner, info in Self.fillPath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "B") { scanner, info in Self.fillAndStrokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "B*") { scanner, info in Self.fillAndStrokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "b") { scanner, info in Self.closeFillAndStrokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "b*") { scanner, info in Self.closeFillAndStrokePath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "n") { scanner, info in Self.endPath(scanner, info) }
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in Self.drawXObject(scanner, info) }
  }

  private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
    guard let info else { return nil }
    return Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
  }

  private static func number(_ scanner: CGPDFScannerRef?) -> CGFloat? {
    guard let scanner else { return nil }
    var value: CGPDFReal = 0
    return CGPDFScannerPopNumber(scanner, &value) ? CGFloat(value) : nil
  }

  private static func saveGraphicsState(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(info) else { return }
    state.graphicsStack.append(state.graphics)
  }

  private static func restoreGraphicsState(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(info), let previous = state.graphicsStack.popLast() else { return }
    state.graphics = previous
  }

  private static func concatenateTransform(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info),
          let f = number(scanner), let e = number(scanner), let d = number(scanner),
          let c = number(scanner), let b = number(scanner), let a = number(scanner) else { return }
    let next = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    state.graphics.transform = next.concatenating(state.graphics.transform)
  }

  private static func setLineWidth(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info), let width = number(scanner) else { return }
    state.graphics.lineWidth = abs(width)
  }

  private static func moveTo(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info), let y = number(scanner), let x = number(scanner) else { return }
    state.beginSubpath(at: CGPoint(x: x, y: y))
  }

  private static func lineTo(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info), let y = number(scanner), let x = number(scanner) else { return }
    state.appendLine(to: CGPoint(x: x, y: y))
  }

  private static func closePath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    state(info)?.closeSubpath()
  }

  private static func rectangle(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info), let height = number(scanner),
          let width = number(scanner), let y = number(scanner), let x = number(scanner) else { return }
    state.appendRectangle(x: x, y: y, width: width, height: height)
  }

  private static func cubicCurve(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner else { return }
    for _ in 0..<6 { _ = number(scanner) }
    state(info)?.appendCurve()
  }

  private static func shortCubicCurve(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner else { return }
    for _ in 0..<4 { _ = number(scanner) }
    state(info)?.appendCurve()
  }

  private static func strokePath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    state(info)?.paint(stroke: true, fill: false)
  }

  private static func closeAndStrokePath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(info) else { return }
    state.closeSubpath()
    state.paint(stroke: true, fill: false)
  }

  private static func fillPath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    state(info)?.paint(stroke: false, fill: true)
  }

  private static func fillAndStrokePath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    state(info)?.paint(stroke: true, fill: true)
  }

  private static func closeFillAndStrokePath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let state = state(info) else { return }
    state.closeSubpath()
    state.paint(stroke: true, fill: true)
  }

  private static func endPath(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    state(info)?.subpaths.removeAll(keepingCapacity: true)
  }

  private static func drawXObject(_ scanner: CGPDFScannerRef?, _ info: UnsafeMutableRawPointer?) {
    guard let scanner, let state = state(info) else { return }
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    state.scanForm(named: String(cString: name), in: scanner)
  }

  private static func horizontalExtent(_ points: [CGPoint], tolerance: CGFloat)
    -> (minX: CGFloat, maxX: CGFloat, y: CGFloat)? {
    guard let first = points.first else { return nil }
    let minY = points.map(\.y).min() ?? first.y
    let maxY = points.map(\.y).max() ?? first.y
    guard maxY - minY <= tolerance else { return nil }
    return (points.map(\.x).min() ?? first.x,
            points.map(\.x).max() ?? first.x,
            (minY + maxY) / 2)
  }

  private static func bounds(of points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .null }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                  width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                  height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
  }

  private static func isSmallRectangle(_ rect: CGRect) -> Bool {
    rect.width >= 0.05 && rect.height >= 0.05 &&
      rect.width <= 16 && rect.height <= 16 &&
      rect.width / rect.height >= 0.1 && rect.width / rect.height <= 10
  }

  private static func rectangularBounds(of points: [CGPoint]) -> CGRect? {
    var corners = points
    if corners.count > 1, corners.first == corners.last { corners.removeLast() }
    guard corners.count == 4 else { return nil }
    let bounds = bounds(of: corners)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let expected = [
      CGPoint(x: bounds.minX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.minY),
      CGPoint(x: bounds.maxX, y: bounds.maxY),
      CGPoint(x: bounds.minX, y: bounds.maxY),
    ]
    guard expected.allSatisfy({ corner in
      corners.contains { abs($0.x - corner.x) <= 0.01 && abs($0.y - corner.y) <= 0.01 }
    }) else { return nil }
    return bounds
  }

  private static func rectangleRows(_ rectangles: [CGRect])
    -> [InkSignPdfPlacementRule] {
    struct Dot {
      let rect: CGRect
      var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }
    var dots: [Dot] = []
    for rectangle in rectangles where isSmallRectangle(rectangle) {
      dots.append(Dot(rect: rectangle))
    }
    dots.sort {
      $0.center.y == $1.center.y
        ? $0.center.x < $1.center.x
        : $0.center.y < $1.center.y
    }
    var groups: [[Dot]] = []
    for dot in dots {
      if let index = groups.indices.first(where: {
        abs(groups[$0][0].center.y - dot.center.y) <= 1.25 &&
          abs(groups[$0][0].rect.height - dot.rect.height) <= 0.75
      }) {
        groups[index].append(dot)
      } else {
        groups.append([dot])
      }
    }

      return groups.compactMap { row in
        guard row.count >= 4 else { return nil }
      let ordered = row.sorted { $0.center.x < $1.center.x }
      let deltas = zip(ordered, ordered.dropFirst()).map { $1.center.x - $0.center.x }
      let mean = deltas.reduce(0, +) / CGFloat(deltas.count)
      guard mean > 0,
            deltas.allSatisfy({ abs($0 - mean) <= max(1.25, mean * 0.3) }) else { return nil }
      let minX = ordered.first!.rect.minX
      let maxX = ordered.last!.rect.maxX
      guard maxX - minX >= 36 else { return nil }
        let y = ordered.map(\.center.y).reduce(0, +) / CGFloat(ordered.count)
        return InkSignPdfPlacementRule(minX: minX, maxX: maxX, y: y)
    }
  }
}
