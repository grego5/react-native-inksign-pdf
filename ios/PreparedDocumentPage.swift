import CoreGraphics
import Foundation

/// Owner-executor cache of immutable source analysis and its four projections.
final class InkSignPdfPreparedPage {
  let analysis: InkSignPdfPageAnalysis
  private var projections: [Int: InkSignPdfProjectedPage] = [:]

  init(analysis: InkSignPdfPageAnalysis) { self.analysis = analysis }

  func projected(geometry: PageGeometry) -> InkSignPdfProjectedPage {
    precondition(Thread.isMainThread)
    if let cached = projections[geometry.rotation] { return cached }
    let matches = analysis.labelCandidates.map(\.match)
    let displayed = analysis.displayedFieldGeometry(
      lookup: InkSignPdfTextLookup(hasLiteralMatch: !matches.isEmpty, matches: matches), geometry: geometry)
    let result = InkSignPdfProjectedPage(geometry: displayed, pageSize: geometry.displaySize)
    projections[geometry.rotation] = result
    return result
  }
}

final class InkSignPdfProjectedPage {
  let geometry: InkSignPdfDisplayedFieldGeometry
  private let pageSize: CGSize
  private struct PairKey: Hashable { let sourceIndex: Int; let rtl: Bool }
  private enum PairResult { case missing; case found(InkSignPdfKeyRulePlacement) }
  private var pairs: [PairKey: PairResult] = [:]

  init(geometry: InkSignPdfDisplayedFieldGeometry, pageSize: CGSize) {
    self.geometry = InkSignPdfDisplayedFieldGeometry(matches: geometry.matches.sorted {
      if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
      if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
      return $0.sourceIndex < $1.sourceIndex
    }, rules: geometry.rules, sourceRules: geometry.sourceRules)
    self.pageSize = pageSize
  }

  func selectPair(lookup: InkSignPdfTextLookup, region: CGRect?,
                  occurrence: InkSignPdfFieldOccurrence, rtl: Bool) -> InkSignPdfKeyRulePlacement? {
    precondition(Thread.isMainThread)
    let matching = Set(lookup.matches.map(\.sourceIndex))
    let candidates = geometry.matches.filter {
      matching.contains($0.sourceIndex) && (region?.contains($0.bounds) ?? true)
    }
    for offset in candidates.indices {
      let match = candidates[occurrence == .first ? offset : candidates.count - offset - 1]
      let key = PairKey(sourceIndex: match.sourceIndex, rtl: rtl)
      if let cached = pairs[key] {
        if case .found(let placement) = cached { return placement }
        continue
      }
      let placement = InkSignPdfKeyRuleSelector.select(matches: [match], rules: geometry.rules,
        occurrence: .first, directionRtl: rtl, pageSize: pageSize)
      pairs[key] = placement.map(PairResult.found) ?? .missing
      if let placement { return placement }
    }
    return nil
  }
}
