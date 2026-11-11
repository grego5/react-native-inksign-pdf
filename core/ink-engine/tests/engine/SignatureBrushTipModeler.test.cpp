#include "modeling/SignatureBrushTipModeler.hpp"
#include "modeling/SignatureStrokeStyle.hpp"
#include "ink-engine/tests/support/TestSupport.hpp"

#include <vector>

using namespace margelo::nitro::inksignpdf;

namespace {
detail::CenterlineState state(double x, double speed, double time,
                             std::size_t source) {
  return {.position = {x, 0}, .velocity = {speed, 0}, .time = time,
          .rawSourceIndex = source, .modeledSourceIndex = source};
}

std::vector<detail::CurrentInkModeledInput> modeledInputs(
    const std::vector<detail::CenterlineState>& states) {
  std::vector<detail::CurrentInkModeledInput> modeled;
  modeled.reserve(states.size());
  for (const auto& value : states)
    modeled.push_back({.state = value});
  return modeled;
}

void samePoints(const std::vector<ModeledPoint>& actual,
                const std::vector<ModeledPoint>& expected) {
  CHECK(actual.size() == expected.size());
  for (std::size_t i = 0; i < actual.size(); ++i) {
    CHECK(actual[i].point.x == expected[i].point.x);
    CHECK(actual[i].point.y == expected[i].point.y);
    CHECK(actual[i].time == expected[i].time);
    CHECK(actual[i].runningLength == expected[i].runningLength);
    CHECK(actual[i].velocity == expected[i].velocity);
    CHECK(actual[i].radius == expected[i].radius);
  }
}
}  // namespace

void checkSignatureBrushOwnership() {
  const InkStrokeConfig config{.minWidth = 2.0, .maxWidth = 4.0, .smoothing = 0.0};
  detail::SignatureBrushTipModeler brush(config);
  std::vector<InkStrokeDiagnosticSample> diagnostics;
  InkStrokeWorkStats stats;
  std::vector<detail::CenterlineState> real{
      state(0, 0, 0, 10), state(3, 300, 0.008, 11),
      state(9, 1200, 0.016, 12), state(18, 900, 0.024, 13)};
  auto modeled = modeledInputs(real);

  auto tips = brush.update({modeled, 0, 2, 900}, stats, &diagnostics);
  CHECK(tips.modeledPointStart == 0);
  CHECK(tips.modeledPoints.data() == brush.modeledPoints().data());
  CHECK(tips.modeledPoints.size() == brush.modeledPoints().size());
  CHECK(!diagnostics.empty());
  CHECK(diagnostics.front().radius == config.minWidth * 0.5);
  CHECK(diagnostics.front().responseAlpha == 0.0);
  CHECK(tips.newFixedUpstreamStates.empty());
  CHECK(tips.volatileUpstreamStates.size() == real.size());

  const auto before = brush.modeledPoints();
  const auto beforeDiagnostics = diagnostics;
  const auto beforeWork = stats;
  auto predictedState = state(45, 2500, 0.032, 14);
  predictedState.predicted = true;
  tips = brush.predict(std::span(&predictedState, 1), &diagnostics);
  CHECK(tips.modeledPoints.data() != brush.modeledPoints().data());
  CHECK(tips.newFixedUpstreamStates.empty());
  CHECK(tips.volatileUpstreamStates.size() == real.size() + 1);
  samePoints(brush.modeledPoints(), before);
  CHECK(stats.widthPointsProcessed == beforeWork.widthPointsProcessed);
  CHECK(stats.styleStatesProcessed == beforeWork.styleStatesProcessed);
  CHECK(stats.tipStatesMaterialized == beforeWork.tipStatesMaterialized);
  CHECK(stats.immutableStatesReused == beforeWork.immutableStatesReused);
  for (std::size_t i = 0; i < beforeDiagnostics.size(); ++i) {
    CHECK(diagnostics[i].radius == beforeDiagnostics[i].radius);
    CHECK(diagnostics[i].dtSeconds == beforeDiagnostics[i].dtSeconds);
    CHECK(diagnostics[i].turnFactor == beforeDiagnostics[i].turnFactor);
    CHECK(diagnostics[i].effectiveSpeedDisplay ==
          beforeDiagnostics[i].effectiveSpeedDisplay);
    CHECK(diagnostics[i].responseDistancePage ==
          beforeDiagnostics[i].responseDistancePage);
  }

  // Replacing from a stable seam restores exactly the same distance state as
  // reconstructing the complete modeled sequence.
  real[2].velocity.x = 700;
  modeled = modeledInputs(real);
  tips = brush.update({modeled, 2, 2, 900}, stats, &diagnostics);
  CHECK(tips.modeledPointStart == 2);
  real.push_back(state(20, 1000, 0.025, 13));
  real.push_back(state(30, 500, 0.033, 14));
  modeled = modeledInputs(real);
  tips = brush.update({modeled, 2, 4, 500}, stats, &diagnostics);
  detail::SignatureBrushTipModeler reconstructedBrush(config);
  InkStrokeWorkStats reconstructedStats;
  reconstructedBrush.update({modeled, 0, modeled.size(), 500},
                            reconstructedStats);
  samePoints(brush.modeledPoints(), reconstructedBrush.modeledPoints());

  real.push_back(state(140, 500, 0.12, 16));
  modeled = modeledInputs(real);
  tips = brush.finish({modeled, 4, modeled.size(), 500}, stats, &diagnostics);
  CHECK(tips.volatileUpstreamStates.back().width > 0.0f);
  CHECK(tips.volatileUpstreamStates.back().position.x ==
        static_cast<float>(brush.modeledPoints().back().point.x));

  brush.reset();
  stats = {};
  real = {state(0, 0, 0, 0), state(1, 50, 0.02, 1)};
  modeled = modeledInputs(real);
  tips = brush.finish({modeled, 0, modeled.size(), 50}, stats, &diagnostics);
  CHECK(diagnostics.back().radius >= config.minWidth * 0.5);
  CHECK(diagnostics.back().radius <= config.maxWidth * 0.5);
  CHECK(tips.volatileUpstreamStates.size() == 2);

  // Lift-off speed continuously controls both terminal attenuation and tail
  // length. The ordinary radius profile is attenuated in place, so differing
  // body and lift-off radii do not create a thin shelf.
  const detail::SignatureStrokeStyle style(1.0, 2.0);
  const auto slow = style.snapshotForSpeed(0.0).snapshot();
  const auto medium = style.snapshotForSpeed(480.0).snapshot();
  const auto fast = style.snapshotForSpeed(1920.0).snapshot();
  const double terminalFloor = style.snapshot().minimumTerminalRadius;
  CHECK(terminalFloor > 0.0);
  CHECK(terminalFloor < style.minimumRadius());
  CHECK(!slow.taper.active());
  CHECK(medium.taper.active());
  CHECK(fast.taper.active());
  CHECK(slow.taper.strength < medium.taper.strength);
  CHECK(medium.taper.strength < fast.taper.strength);
  CHECK(slow.taper.distance < medium.taper.distance);
  CHECK(medium.taper.distance < fast.taper.distance);
  CHECK(fast.maximumTaperDistance == 48.0);

  const double slowEnd = detail::SignatureStrokeStyle::terminalRadiusAt(
      1.0, 0.0, fast.taper.distance, slow.taper.strength, terminalFloor);
  const double fastEnd = detail::SignatureStrokeStyle::terminalRadiusAt(
      1.0, 0.0, fast.taper.distance, fast.taper.strength, terminalFloor);
  const double bodyMid = detail::SignatureStrokeStyle::terminalRadiusAt(
      2.0, fast.taper.distance * 0.5, fast.taper.distance,
      fast.taper.strength, terminalFloor);
  const double liftMid = detail::SignatureStrokeStyle::terminalRadiusAt(
      1.0, fast.taper.distance * 0.5, fast.taper.distance,
      fast.taper.strength, terminalFloor);
  const double joined = detail::SignatureStrokeStyle::terminalRadiusAt(
      2.0, fast.taper.distance, fast.taper.distance, fast.taper.strength,
      terminalFloor);
  const double extremeEnd = detail::SignatureStrokeStyle::terminalRadiusAt(
      1.0, 0.0, 80.0, 1.0, terminalFloor);
  const double extremeNearEndpoint =
      detail::SignatureStrokeStyle::terminalRadiusAt(
          2.0, 20.0, 80.0, 1.0, terminalFloor);
  const double extremeNearBody = detail::SignatureStrokeStyle::terminalRadiusAt(
      2.0, 60.0, 80.0, 1.0, terminalFloor);
  CHECK(slowEnd == 1.0);
  CHECK(fastEnd < slowEnd);
  CHECK(extremeEnd == terminalFloor);
  CHECK(extremeNearEndpoint == 0.5);
  CHECK(extremeNearBody == 1.5);
  CHECK(bodyMid > liftMid);
  CHECK(bodyMid < 2.0);
  CHECK(joined == 2.0);

  brush.reset();
  const detail::NormalizedInput dot{.eventType = InkStrokeEventType::Down,
                                    .position = {2, 3}, .time = 0.1};
  tips = brush.finishDot(dot, 1.5);
  CHECK(brush.modeledPoints().size() == 1);
  CHECK(brush.modeledPoints().front().radius == 1.5);
  CHECK(tips.volatileUpstreamStates.size() == 1);
  CHECK(tips.volatileUpstreamStates.front().width == 3.0f);
}
