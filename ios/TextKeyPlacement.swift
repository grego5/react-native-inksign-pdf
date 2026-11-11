import CoreGraphics
import Foundation

struct InkSignPdfKeyRulePlacement {
  let match: InkSignPdfKeyTextMatch
  let rule: InkSignPdfPlacementRule
  let contentMinX: CGFloat
  let contentMaxX: CGFloat
}

private struct InkSignPdfKeyRuleFit {
  let rule: InkSignPdfPlacementRule
  let contentMinX: CGFloat
  let contentMaxX: CGFloat
  let horizontalGap: CGFloat
  let verticalGap: CGFloat
}

private let keyInsertionLabelMarginPoints: CGFloat = 2

enum InkSignPdfFieldOccurrence: Equatable {
  case first
  case last
}

enum InkSignPdfKeyRuleSelector {
  static func select(matches: [InkSignPdfKeyTextMatch],
                     rules: [InkSignPdfPlacementRule],
                     occurrence: InkSignPdfFieldOccurrence,
                     directionRtl: Bool?,
                     pageSize: CGSize) -> InkSignPdfKeyRulePlacement? {
    let directions = directionRtl.map { [$0] } ?? [false, true]
    let orderedMatches = matches.sorted {
      if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
      if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
      return $0.sourceIndex < $1.sourceIndex
    }
    for matchIndex in orderedMatches.indices {
      let orderedIndex: Int
      switch occurrence {
      case .first: orderedIndex = matchIndex
      case .last: orderedIndex = orderedMatches.count - matchIndex - 1
      }
      let match = orderedMatches[orderedIndex]
      let centerY = match.lineCenterY ?? match.bounds.midY
      guard match.lineHeight.isFinite, match.lineHeight > 0, centerY.isFinite else { continue }

      var bestFit: InkSignPdfKeyRuleFit?
      for candidate in rules {
        guard candidate.minX.isFinite && candidate.maxX.isFinite && candidate.y.isFinite &&
          candidate.minX >= 0 && candidate.maxX <= pageSize.width && candidate.maxX > candidate.minX &&
          candidate.y >= 0 && candidate.y <= pageSize.height else { continue }
        for rtl in directions {
          let overlapsLabel = rtl
            ? candidate.maxX > match.bounds.minX
            : candidate.minX < match.bounds.maxX
          let isOnDirectionSide = rtl
            ? candidate.minX < match.bounds.minX
            : candidate.maxX > match.bounds.maxX
          let contentMinX = rtl || !overlapsLabel
            ? candidate.minX
            : match.bounds.maxX + keyInsertionLabelMarginPoints
          let contentMaxX = !rtl || !overlapsLabel
            ? candidate.maxX
            : match.bounds.minX - keyInsertionLabelMarginPoints
          let horizontalGap = rtl
            ? match.bounds.minX - contentMaxX
            : contentMinX - match.bounds.maxX
          let verticalGap = abs(candidate.y - centerY)
          guard isOnDirectionSide, contentMaxX > contentMinX, horizontalGap >= 0,
                verticalGap <= match.lineHeight else { continue }

          let isBetter: Bool
          if let current = bestFit {
            if horizontalGap != current.horizontalGap {
              isBetter = horizontalGap < current.horizontalGap
            } else if verticalGap != current.verticalGap {
              isBetter = verticalGap < current.verticalGap
            } else if candidate.minX != current.rule.minX {
              isBetter = candidate.minX < current.rule.minX
            } else {
              isBetter = candidate.y < current.rule.y
            }
          } else {
            isBetter = true
          }
          if isBetter {
            bestFit = InkSignPdfKeyRuleFit(rule: candidate,
                                           contentMinX: contentMinX,
                                           contentMaxX: contentMaxX,
                                           horizontalGap: horizontalGap,
                                           verticalGap: verticalGap)
          }
        }
      }
      if let bestFit {
        return InkSignPdfKeyRulePlacement(match: match,
                                          rule: bestFit.rule,
                                          contentMinX: bestFit.contentMinX,
                                          contentMaxX: bestFit.contentMaxX)
      }
    }
    return nil
  }
}

