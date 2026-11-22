#include "ink-engine/tests/support/TestSupport.hpp"
#include "primitives/StrokePrimitives.hpp"
#include "modeling/SignatureStrokeStyle.hpp"
#include "modeling/VelocityWidthModel.hpp"

#include <algorithm>
#include <cmath>

using namespace margelo::nitro::inksignpdf;
using namespace margelo::nitro::inksignpdf::detail;

namespace {
NormalizedInput point(InkStrokeEventType event, double x, double time,
                      double y = 0.0) {
  return {.eventType = event, .position = {x, y}, .time = time};
}

bool near(double first, double second, double tolerance = 1e-12) {
  return std::abs(first - second) <= tolerance *
      std::max({1.0, std::abs(first), std::abs(second)});
}

double referenceTarget(double minimum, double maximum,
                       double effectiveSpeedDisplay) {
  const double x = effectiveSpeedDisplay / 960.0;
  const double u = std::exp(-4.0 * std::exp(-4.0 * x));
  return minimum + u * (maximum - minimum);
}

double referenceTurnFactor(Vec2 previous, Vec2 current, double dt) {
  const double previousLength = length(previous);
  const double currentLength = length(current);
  if (!(dt > 0.0) || !(previousLength > 0.0) || !(currentLength > 0.0))
    return 1.0;
  const double cosine = std::clamp(
      dot(scale(previous, 1.0 / previousLength),
          scale(current, 1.0 / currentLength)),
      -1.0, 1.0);
  const double angle = std::acos(cosine);
  return std::pow(std::clamp(
                      (std::cos((angle / dt) / 90.0) - 0.65) / 0.35,
                      0.0, 1.0),
                  3.0);
}
}  // namespace

int main() {
  constexpr double minimum = 1.0;
  constexpr double maximum = 2.0;
  SignatureStrokeStyle style(minimum, maximum);

  // The continuous target uses the supplied recurrence directly. In
  // particular, zero speed is not the minimum-radius target and 960 is not a
  // saturation threshold.
  CHECK(near(style.radiusTargetForEffectiveSpeedDisplay(
                 0.0),
             referenceTarget(minimum, maximum, 0.0)));
  CHECK(near(style.radiusTargetForEffectiveSpeedDisplay(
                 SignatureStrokeStyle::kVelocityReferenceRate),
             referenceTarget(minimum, maximum, 960.0)));
  CHECK(near(style.radiusTargetForEffectiveSpeedDisplay(1920.0),
             referenceTarget(minimum, maximum, 1920.0)));

  VelocityWidthModel model(style);
  const auto first = model.begin(point(InkStrokeEventType::Down, 0.0, 10.0),
                                 {960.0, 0.0});
  CHECK(first.radius == minimum);
  CHECK(first.dtSeconds == 0.0);
  CHECK(first.turnFactor == 1.0);
  CHECK(first.effectiveSpeedDisplay == 960.0);
  CHECK(near(first.targetRadius, referenceTarget(minimum, maximum, 960.0)));
  CHECK(first.segmentDistance == 0.0);
  CHECK(first.responseDistancePage == style.responseDistancePage());
  CHECK(first.responseAlpha == 0.0);

  CHECK(near(style.brushSizePage(), 4.0));
  CHECK(near(style.distanceResponseStrength(), 6.0));
  CHECK(near(style.distanceResponseStrength(true), 2.0));
  CHECK(near(style.responseDistancePage(), 24.0));
  CHECK(near(style.responseDistancePage(true), 8.0));

  // Configured display widths map to six maximum brush diameters in page
  // space. The response distance is frozen from the page-space style.
  CHECK(near(SignatureStrokeStyle(0.5, 1.0).responseDistancePage(), 12.0));
  CHECK(near(SignatureStrokeStyle(1.0, 2.0).responseDistancePage(), 24.0));
  CHECK(near(SignatureStrokeStyle(2.0, 4.0).responseDistancePage(), 48.0));

  // The response is exponential in traveled distance and independent of
  // event timing. One response distance completes 1 - exp(-1) of the gap.
  const auto oneResponseDistance = model.update(
      point(InkStrokeEventType::Move, 24.0, 10.001), {9600.0, 0.0});
  CHECK(near(oneResponseDistance.segmentDistance, 24.0));
  CHECK(near(oneResponseDistance.responseAlpha, -std::expm1(-1.0)));
  CHECK(near(oneResponseDistance.radius,
             minimum + oneResponseDistance.responseAlpha *
                 (oneResponseDistance.targetRadius - minimum)));

  // Equal-target subdivision composes exactly by distance.
  VelocityWidthModel subdivided(style);
  subdivided.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {9600.0, 0.0});
  subdivided.update(point(InkStrokeEventType::Move, 12.0, 1.0), {9600.0, 0.0});
  const auto twoHalfDistances = subdivided.update(
      point(InkStrokeEventType::Move, 24.0, 100.0), {9600.0, 0.0});
  CHECK(near(twoHalfDistances.radius, oneResponseDistance.radius));

  // Growth and contraction use the same exponential update with separate
  // response distances.
  VelocityWidthModel bounded(style);
  bounded.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {0.0, 0.0});
  const auto growth = bounded.update(
      point(InkStrokeEventType::Move, 10.0, 0.1), {9600.0, 0.0});
  CHECK(growth.radius > minimum);
  CHECK(near(growth.responseDistancePage, style.responseDistancePage()));
  const auto contraction = bounded.update(
      point(InkStrokeEventType::Move, 20.0, 0.2), {0.0, 0.0});
  CHECK(contraction.radius < growth.radius);
  CHECK(near(contraction.responseDistancePage,
             style.responseDistancePage(true)));
  CHECK(near(contraction.responseAlpha,
             -std::expm1(-contraction.segmentDistance /
                         style.responseDistancePage(true))));

  // Zero travel cannot change radius, regardless of elapsed time.
  VelocityWidthModel noAllowance(style);
  noAllowance.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {9600.0, 0.0});
  const auto zeroTravel = noAllowance.update(
      point(InkStrokeEventType::Move, 0.0, 0.1), {9600.0, 0.0});
  CHECK(zeroTravel.segmentDistance == 0.0);
  CHECK(zeroTravel.responseDistancePage == style.responseDistancePage());
  CHECK(zeroTravel.responseAlpha == 0.0);
  CHECK(zeroTravel.radius == minimum);
  const auto next = noAllowance.update(
      point(InkStrokeEventType::Move, 24.0, 0.1), {9600.0, 0.0});
  CHECK(near(next.responseAlpha, -std::expm1(-1.0)));
  CHECK(next.radius > zeroTravel.radius);

  // Direction changes attenuate effective speed, while zero velocity on
  // either side leaves the factor at one. A high angular rate retains the
  // supplied periodic cosine behavior.
  VelocityWidthModel directions(style);
  directions.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {100.0, 0.0});
  const auto straight = directions.update(
      point(InkStrokeEventType::Move, 1.0, 0.1), {100.0, 0.0});
  CHECK(near(straight.turnFactor, 1.0));
  const auto changed = directions.update(
      point(InkStrokeEventType::Move, 2.0, 0.2), {0.0, 100.0});
  CHECK(near(changed.turnFactor,
             referenceTurnFactor({100.0, 0.0}, {0.0, 100.0}, 0.1)));
  CHECK(changed.turnFactor < 1.0);

  VelocityWidthModel zeroPrevious(style);
  zeroPrevious.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {0.0, 0.0});
  CHECK(zeroPrevious.update(point(InkStrokeEventType::Move, 1.0, 0.1),
                            {100.0, 0.0}).turnFactor == 1.0);
  VelocityWidthModel zeroCurrent(style);
  zeroCurrent.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {100.0, 0.0});
  CHECK(zeroCurrent.update(point(InkStrokeEventType::Move, 1.0, 0.1),
                           {0.0, 0.0}).turnFactor == 1.0);
  VelocityWidthModel periodic(style);
  periodic.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {100.0, 0.0});
  const auto periodicTurn = periodic.update(
      point(InkStrokeEventType::Move, 1.0, 1.0 / 180.0), {-100.0, 0.0});
  CHECK(near(periodicTurn.turnFactor,
             referenceTurnFactor({100.0, 0.0}, {-100.0, 0.0}, 1.0 / 180.0)));
  CHECK(near(periodicTurn.turnFactor, 1.0));
  VelocityWidthModel tinyDt(style);
  tinyDt.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {100.0, 0.0});
  const auto tiny = tinyDt.update(point(InkStrokeEventType::Move, 1.0, 1e-12),
                                  {0.0, 100.0});
  CHECK(near(tiny.turnFactor,
             referenceTurnFactor({100.0, 0.0}, {0.0, 100.0}, 1e-12)));

  // Page-space scaling preserves displayed widths when both the page
  // geometry and configured radii are converted consistently.
  SignatureStrokeStyle scaledStyle(0.5, 1.0, 2.0);
  SignatureStrokeStyle displayStyle(1.0, 2.0, 1.0);
  CHECK(near(scaledStyle.responseDistancePage(), 12.0));
  CHECK(near(displayStyle.responseDistancePage(), 24.0));
  VelocityWidthModel scaled(scaledStyle);
  VelocityWidthModel display(displayStyle);
  scaled.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {100.0, 0.0});
  display.begin(point(InkStrokeEventType::Down, 0.0, 0.0), {200.0, 0.0});
  const auto scaledResult = scaled.update(
      point(InkStrokeEventType::Move, 5.0, 0.1), {100.0, 0.0});
  const auto displayResult = display.update(
      point(InkStrokeEventType::Move, 10.0, 0.1), {200.0, 0.0});
  CHECK(near(scaledResult.responseAlpha, displayResult.responseAlpha));
  CHECK(near(scaledResult.radius * 2.0, displayResult.radius));
  CHECK(near(scaledResult.targetRadius * 2.0, displayResult.targetRadius));

  // Snapshot/restore includes the complete causal recurrence state, including
  // the timestamp and velocity needed by the first restored turn sample.
  VelocityWidthModel uninitialized(style);
  const auto initialSnapshot = uninitialized.snapshot();
  VelocityWidthModel restoredBeforeBegin(style);
  restoredBeforeBegin.restore(initialSnapshot);
  const auto initial = uninitialized.begin(
      point(InkStrokeEventType::Down, 0.0, 4.0), {100.0, 0.0});
  const auto restoredInitial = restoredBeforeBegin.begin(
      point(InkStrokeEventType::Down, 0.0, 4.0), {100.0, 0.0});
  CHECK(near(initial.radius, restoredInitial.radius));
  CHECK(near(initial.targetRadius, restoredInitial.targetRadius));

  VelocityWidthModel checkpoint(style);
  checkpoint.begin(point(InkStrokeEventType::Down, 0.0, 4.0), {100.0, 0.0});
  checkpoint.update(point(InkStrokeEventType::Move, 1.0, 4.1), {100.0, 0.0});
  const auto saved = checkpoint.snapshot();
  const auto direct = checkpoint.update(
      point(InkStrokeEventType::Move, 2.0, 4.2), {0.0, 100.0});
  VelocityWidthModel restored(style);
  restored.restore(saved);
  const auto replayed = restored.update(
      point(InkStrokeEventType::Move, 2.0, 4.2), {0.0, 100.0});
  CHECK(near(replayed.dtSeconds, direct.dtSeconds));
  CHECK(near(replayed.turnFactor, direct.turnFactor));
  CHECK(near(replayed.effectiveSpeedDisplay, direct.effectiveSpeedDisplay));
  CHECK(near(replayed.targetRadius, direct.targetRadius));
  CHECK(near(replayed.responseDistancePage, direct.responseDistancePage));
  CHECK(near(replayed.responseAlpha, direct.responseAlpha));
  CHECK(near(replayed.radius, direct.radius));

  SignatureStrokeStyle fixedStyle(0.0, 0.0);
  VelocityWidthModel fixed(fixedStyle);
  CHECK(fixed.begin(point(InkStrokeEventType::Down, 0.0, 0.0),
                    {960.0, 0.0}).radius == 0.0);
  const auto fixedMove = fixed.update(
      point(InkStrokeEventType::Move, 100.0, 0.1), {0.0, 960.0});
  CHECK(fixedMove.radius == 0.0);
  CHECK(fixedMove.responseDistancePage == 0.0);

  checkpoint.cancel();
  CHECK(checkpoint.begin(point(InkStrokeEventType::Down, 100.0, 9.0),
                         {1200.0, 0.0}).radius == minimum);
  return 0;
}
