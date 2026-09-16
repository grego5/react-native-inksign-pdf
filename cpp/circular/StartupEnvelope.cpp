#include "circular/StartupEnvelope.hpp"
#include "circular/CubicBezierMath.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace margelo::nitro::inksignpdf::startup {
namespace {

double dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
Vec2 subtract(Vec2 a, Vec2 b) { return {a.x - b.x, a.y - b.y}; }
bool finite(Vec2 p) { return std::isfinite(p.x) && std::isfinite(p.y); }
double length(Vec2 p) { return std::hypot(p.x, p.y); }

// Work relative to the section origin, avoiding cancellation from page offsets.
CubicSegment relativeCurve(const CubicSegment& curve, Vec2 origin) {
  return {subtract(curve.p0, origin), subtract(curve.c1, origin),
          subtract(curve.c2, origin), subtract(curve.p3, origin)};
}

double projection(const CubicSegment& curve, Vec2 axis, double t) {
  return dot(detail::cubicPoint(curve, t), axis);
}

// Split the cubic projection into monotone intervals at all derivative roots.
// A cubic supplies at most two internal critical parameters and three crossings.
std::size_t projectionKnots(const CubicSegment& curve, Vec2 axis,
                            std::array<double, 4>& knots) {
  const double d0 = dot(detail::cubicDerivative(curve, 0.0), axis);
  const double dm = dot(detail::cubicDerivative(curve, 0.5), axis);
  const double d1 = dot(detail::cubicDerivative(curve, 1.0), axis);
  const double a = 2.0 * (d1 - 2.0 * dm + d0);
  const double b = d1 - d0 - a;
  const double c = d0;
  const double scale = std::max({std::abs(a), std::abs(b), std::abs(c)});
  const double epsilon = 32.0 * std::numeric_limits<double>::epsilon() * scale;
  std::size_t count = 1;
  knots[0] = 0.0;
  const auto append = [&](double t) {
    if (std::isfinite(t) && t > 0.0 && t < 1.0) knots[count++] = t;
  };
  if (std::abs(a) <= epsilon) {
    if (std::abs(b) > epsilon) append(-c / b);
  } else {
    const double discriminant = b * b - 4.0 * a * c;
    if (discriminant >= 0.0) {
      const double q = -0.5 * (b + std::copysign(std::sqrt(discriminant), b));
      if (q == 0.0) append(-b / (2.0 * a));
      else {
        append(q / a);
        append(c / q);
      }
    }
  }
  knots[count++] = 1.0;
  std::sort(knots.begin(), knots.begin() + static_cast<std::ptrdiff_t>(count));
  const auto end = std::unique(
      knots.begin(), knots.begin() + static_cast<std::ptrdiff_t>(count));
  return static_cast<std::size_t>(end - knots.begin());
}

double crossingParameter(const CubicSegment& curve, Vec2 tangent,
                         double low, double high, bool increasing) {
  if (projection(curve, tangent, low) == 0.0) return low;
  if (projection(curve, tangent, high) == 0.0) return high;
  for (int iteration = 0; iteration < 60; ++iteration) {
    const double middle = (low + high) * 0.5;
    if ((projection(curve, tangent, middle) < 0.0) == increasing)
      low = middle;
    else
      high = middle;
  }
  return (low + high) * 0.5;
}

struct Drawdown {
  double peak = 0.0;
  double trough = 0.0;
  double maximum = 0.0;
  double valley = 0.0;
  bool initialized = false;

  void observe(double value) {
    if (!initialized) {
      peak = trough = value;
      initialized = true;
      return;
    }
    trough = std::min(trough, value);
    maximum = std::max(maximum, peak - value);
    // Both descent and subsequent ascent are necessary for a valley witness.
    valley = std::max(valley, std::min(peak - trough, value - trough));
    if (value >= peak) peak = trough = value;
  }
};

}  // namespace

StartupEnvelopeEvaluator::StartupEnvelopeEvaluator(
    StartupEnvelopeConfig geometry, StartupEvidenceLimits limits)
    : geometry_(geometry), limits_(limits) {
  if (!std::isfinite(geometry.geometryEpsilon) || geometry.geometryEpsilon <= 0.0 ||
      !std::isfinite(geometry.arcTolerance) || geometry.arcTolerance <= 0.0 ||
      limits.maxSections == 0 || limits.maxContours == 0 || limits.maxSegments == 0)
    throw std::invalid_argument("invalid startup evidence configuration");
}

StartupEvidenceReason StartupEnvelopeEvaluator::measureSection(
    std::span<const StrokeContour> contours, const StartupSection& section,
    double& left, double& right, StartupEnvelopeEvidence& evidence) {
  const double tangentLength = length(section.tangent);
  const Vec2 tangent{section.tangent.x / tangentLength,
                     section.tangent.y / tangentLength};
  const Vec2 normal{-tangent.y, tangent.x};
  intervals_.clear();
  bool touchesContact = false;
  for (const auto& contour : contours) {
    crossings_.clear();
    for (const auto& segment : contour.path.segments) {
      ++evidence.segmentsVisited;
      const CubicSegment curve = relativeCurve(segment, section.center);
      if (length(curve.p0) <= geometry_.geometryEpsilon ||
          length(curve.p3) <= geometry_.geometryEpsilon)
        touchesContact = true;
      const double q0 = dot(curve.p0, tangent);
      const double q1 = dot(curve.c1, tangent);
      const double q2 = dot(curve.c2, tangent);
      const double q3 = dot(curve.p3, tangent);
      const double scale = std::max({std::abs(q0), std::abs(q1),
                                     std::abs(q2), std::abs(q3)});
      // A side lying in the cross-section has no unique point intersection.
      if (scale == 0.0)
        return StartupEvidenceReason::AmbiguousCrossSection;
      std::array<double, 4> knots{};
      const std::size_t count = projectionKnots(curve, tangent, knots);
      for (std::size_t i = 1; i < count; ++i) {
        const double low = projection(curve, tangent, knots[i - 1]);
        const double high = projection(curve, tangent, knots[i]);
        // Half-open crossing rule: adjacent segments and a tangent root cancel
        // correctly, including a vertex on the cross-section.
        const bool increasing = low <= 0.0 && high > 0.0;
        const bool decreasing = high <= 0.0 && low > 0.0;
        if (!increasing && !decreasing) continue;
        const double t = crossingParameter(curve, tangent, knots[i - 1],
                                           knots[i], increasing);
        const double lateral = projection(curve, normal, t);
        if (!std::isfinite(lateral))
          return StartupEvidenceReason::InvalidContour;
        crossings_.push_back({lateral, increasing ? 1 : -1});
      }
    }
    std::sort(crossings_.begin(), crossings_.end(),
              [](const auto& a, const auto& b) { return a.lateral < b.lateral; });
    int winding = 0;
    double start = 0.0;
    for (std::size_t i = 0; i < crossings_.size();) {
      const double position = crossings_[i].lateral;
      int delta = 0;
      do {
        delta += crossings_[i++].windingDelta;
      } while (i < crossings_.size() &&
               std::abs(crossings_[i].lateral - position) <= geometry_.geometryEpsilon);
      const int next = winding + delta;
      if (winding == 0 && next != 0) start = position;
      if (winding != 0 && next == 0)
        intervals_.push_back({start, position});
      winding = next;
    }
    if (winding != 0) return StartupEvidenceReason::AmbiguousCrossSection;
  }

  std::sort(intervals_.begin(), intervals_.end(),
            [](const auto& a, const auto& b) { return a.low < b.low; });
  if (section.phase == StartupPhase::Contact && intervals_.empty()) {
    // Only an observed endpoint with no filled interval gets zero width.
    // An absent contour is not an exposed contact. With filled coverage below,
    // retain the measured width, including ordinary endpoint-radius coverage.
    if (!touchesContact)
      return StartupEvidenceReason::InvalidTerminalContact;
    evidence.contact = StartupContactObservation::ZeroWidthEndpoint;
    evidence.contactWidth = 0.0;
    left = right = 0.0;
    return StartupEvidenceReason::None;
  }
  if (intervals_.empty()) return StartupEvidenceReason::MissingCenterCoverage;
  Interval visible = intervals_.front();
  for (std::size_t i = 1; i < intervals_.size(); ++i) {
    if (intervals_[i].low > visible.high + geometry_.geometryEpsilon)
      return StartupEvidenceReason::AmbiguousCrossSection;
    visible.high = std::max(visible.high, intervals_[i].high);
  }
  if (visible.low > geometry_.geometryEpsilon ||
      visible.high < -geometry_.geometryEpsilon)
    return StartupEvidenceReason::MissingCenterCoverage;
  left = std::max(0.0, visible.high);
  right = std::max(0.0, -visible.low);
  if (section.phase == StartupPhase::Contact) {
    evidence.contact = StartupContactObservation::NonzeroWidth;
    evidence.contactWidth = left + right;
  }
  return StartupEvidenceReason::None;
}

StartupEnvelopeEvidence StartupEnvelopeEvaluator::evaluate(
    std::span<const StrokeContour> contours,
    std::span<const StartupSection> sections) {
  StartupEnvelopeEvidence result;
  result.comparisonTolerance =
      32.0 * geometry_.geometryEpsilon + 2.0 * geometry_.arcTolerance;
  const auto unsupported = [&](StartupEvidenceReason reason) {
    result.status = StartupEvidenceStatus::Unsupported;
    result.reason = reason;
    return result;
  };
  if (sections.empty() || contours.empty())
    return unsupported(StartupEvidenceReason::InvalidSections);
  if (sections.size() > limits_.maxSections || contours.size() > limits_.maxContours)
    return unsupported(StartupEvidenceReason::WorkLimit);
  std::size_t segmentCount = 0;
  for (const auto& contour : contours) {
    if (contour.path.segments.size() > limits_.maxSegments - segmentCount)
      return unsupported(StartupEvidenceReason::WorkLimit);
    segmentCount += contour.path.segments.size();
    if (!contour.path.closed || contour.path.segments.empty())
      return unsupported(StartupEvidenceReason::InvalidContour);
    Vec2 previous = contour.path.segments.back().p3;
    for (const auto& curve : contour.path.segments) {
      if (!finite(curve.p0) || !finite(curve.c1) || !finite(curve.c2) ||
          !finite(curve.p3) ||
          length(subtract(previous, curve.p0)) > geometry_.geometryEpsilon)
        return unsupported(StartupEvidenceReason::InvalidContour);
      previous = curve.p3;
    }
  }
  for (std::size_t i = 0; i < sections.size(); ++i) {
    const auto& section = sections[i];
    if (!finite(section.center) || !finite(section.tangent) ||
        !std::isfinite(length(section.tangent)) || length(section.tangent) == 0.0 ||
        !std::isfinite(section.arclength) || section.arclength < 0.0 ||
        section.phase < StartupPhase::Nose || section.phase > StartupPhase::Contact ||
        (section.phase == StartupPhase::Contact && i + 1 != sections.size()) ||
        (i > 0 && (section.arclength <= sections[i - 1].arclength ||
                   section.phase < sections[i - 1].phase)))
      return unsupported(StartupEvidenceReason::InvalidSections);
  }

  Drawdown leftTrend, rightTrend, widthTrend;
  double terminalMinimum = 0.0;
  bool terminalStarted = false;
  bool terminalExpansion = false;
  for (const auto& section : sections) {
    double left = 0.0, right = 0.0;
    const auto reason = measureSection(contours, section, left, right, result);
    if (reason != StartupEvidenceReason::None) return unsupported(reason);
    const double width = left + right;
    if (result.sectionsEvaluated == 0) result.minimumWidth = result.maximumWidth = width;
    else {
      result.minimumWidth = std::min(result.minimumWidth, width);
      result.maximumWidth = std::max(result.maximumWidth, width);
    }
    ++result.sectionsEvaluated;
    if (section.phase == StartupPhase::Nose) continue;
    if (section.phase == StartupPhase::Widening || section.phase == StartupPhase::BodyJoin) {
      leftTrend.observe(left);
      rightTrend.observe(right);
      widthTrend.observe(width);
      terminalMinimum = width;
    } else {
      if (!terminalStarted) {
        // Include the join-to-terminal transition if there was a join.
        if (!widthTrend.initialized) terminalMinimum = width;
        terminalStarted = true;
      }
      terminalExpansion |= width > terminalMinimum + result.comparisonTolerance;
      terminalMinimum = std::min(terminalMinimum, width);
    }
  }
  result.maximumLeftInward = leftTrend.maximum;
  result.maximumRightInward = rightTrend.maximum;
  result.maximumWidthDrawdown = widthTrend.maximum;
  result.widthValleyDepth = widthTrend.valley;
  result.status = StartupEvidenceStatus::Violation;
  if (result.widthValleyDepth > result.comparisonTolerance)
    result.reason = StartupEvidenceReason::WidthValley;
  else if (result.maximumLeftInward > result.comparisonTolerance ||
           result.maximumRightInward > result.comparisonTolerance)
    result.reason = StartupEvidenceReason::InwardSideMovement;
  else if (terminalExpansion)
    result.reason = StartupEvidenceReason::TerminalExpansion;
  else {
    result.status = StartupEvidenceStatus::NoViolationAtSections;
    result.reason = StartupEvidenceReason::None;
  }
  return result;
}

}  // namespace margelo::nitro::inksignpdf::startup
